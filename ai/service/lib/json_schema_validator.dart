import 'dart:convert';

/// Valida [value] contra un subconjunto de JSON Schema: `type`, `enum`,
/// `const`, `anyOf`, `properties`, `required`, `additionalProperties: false`,
/// `items`, `minItems`, `maxItems`, `minLength`, `maxLength`, `minimum` y
/// `maximum`. Las palabras clave desconocidas se ignoran.
///
/// DeepSeek solo garantiza JSON sintácticamente válido (`json_object`), no que
/// cumpla el esquema; esta comprobación cierra esa diferencia en el servidor.
/// Los mensajes contienen rutas y reglas, nunca el contenido generado.
List<String> validateJsonSchema(
  Object? value,
  Map<String, dynamic> schema, [
  String path = r'$',
]) {
  final errors = <String>[];

  final anyOf = schema['anyOf'];
  if (anyOf is List) {
    final matches = anyOf.whereType<Map<String, dynamic>>().any(
          (option) => validateJsonSchema(value, option, path).isEmpty,
        );
    if (!matches) errors.add('$path: no cumple ninguna alternativa de anyOf');
    return errors;
  }

  if (schema.containsKey('const') &&
      jsonEncode(schema['const']) != jsonEncode(value)) {
    errors.add('$path: valor distinto de const');
  }
  final allowed = schema['enum'];
  if (allowed is List &&
      !allowed.any((item) => jsonEncode(item) == jsonEncode(value))) {
    errors.add('$path: valor fuera de enum');
  }

  final type = schema['type'];
  final types = type is String
      ? [type]
      : type is List
          ? type.whereType<String>().toList()
          : const <String>[];
  if (types.isNotEmpty && !types.any((name) => _isType(value, name))) {
    errors.add('$path: se esperaba ${types.join(' | ')}');
    return errors;
  }

  if (value is String) {
    final min = schema['minLength'];
    final max = schema['maxLength'];
    if (min is int && value.runes.length < min) {
      errors.add('$path: menos de $min caracteres');
    }
    if (max is int && value.runes.length > max) {
      errors.add('$path: más de $max caracteres');
    }
  } else if (value is num) {
    final min = schema['minimum'];
    final max = schema['maximum'];
    if (min is num && value < min) errors.add('$path: menor que $min');
    if (max is num && value > max) errors.add('$path: mayor que $max');
  } else if (value is List) {
    final min = schema['minItems'];
    final max = schema['maxItems'];
    if (min is int && value.length < min) {
      errors.add('$path: menos de $min elementos');
    }
    if (max is int && value.length > max) {
      errors.add('$path: más de $max elementos');
    }
    final items = schema['items'];
    if (items is Map<String, dynamic>) {
      for (var i = 0; i < value.length; i++) {
        errors.addAll(validateJsonSchema(value[i], items, '$path[$i]'));
      }
    }
  } else if (value is Map) {
    final properties = schema['properties'];
    final declared = properties is Map<String, dynamic>
        ? properties
        : const <String, dynamic>{};
    final required = schema['required'];
    if (required is List) {
      for (final name in required.whereType<String>()) {
        if (!value.containsKey(name)) {
          errors.add('$path.$name: propiedad obligatoria ausente');
        }
      }
    }
    for (final entry in value.entries) {
      final name = entry.key.toString();
      final child = declared[name];
      if (child is Map<String, dynamic>) {
        errors.addAll(validateJsonSchema(entry.value, child, '$path.$name'));
      } else if (schema['additionalProperties'] == false) {
        errors.add('$path.$name: propiedad no declarada');
      }
    }
  }
  return errors;
}

/// Construye un ejemplo mínimo de la estructura esperada a partir de [schema].
/// DeepSeek JSON Output pide incluir un ejemplo de la forma del JSON en el
/// prompt; los valores son marcadores, no contenido real.
Object? exampleFromSchema(Map<String, dynamic> schema, [int depth = 0]) {
  if (depth > 8) return null;
  final options = schema['enum'];
  if (options is List && options.isNotEmpty) return options.first;
  if (schema.containsKey('const')) return schema['const'];
  final anyOf = schema['anyOf'];
  if (anyOf is List && anyOf.isNotEmpty && anyOf.first is Map<String, dynamic>) {
    return exampleFromSchema(anyOf.first as Map<String, dynamic>, depth + 1);
  }
  final type = schema['type'];
  final name = type is String
      ? type
      : type is List
          ? type.whereType<String>().firstWhere((t) => t != 'null',
              orElse: () => 'null')
          : 'object';
  switch (name) {
    case 'object':
      final properties = schema['properties'];
      if (properties is! Map<String, dynamic>) return <String, Object?>{};
      return {
        for (final entry in properties.entries)
          entry.key: entry.value is Map<String, dynamic>
              ? exampleFromSchema(entry.value as Map<String, dynamic>, depth + 1)
              : null,
      };
    case 'array':
      final items = schema['items'];
      return [
        if (items is Map<String, dynamic>)
          exampleFromSchema(items, depth + 1),
      ];
    case 'string':
      return 'texto';
    case 'integer':
    case 'number':
      return schema['minimum'] ?? 0;
    case 'boolean':
      return false;
    default:
      return null;
  }
}

bool _isType(Object? value, String type) => switch (type) {
      'object' => value is Map,
      'array' => value is List,
      'string' => value is String,
      'boolean' => value is bool,
      'null' => value == null,
      'number' => value is num,
      'integer' =>
        value is int || (value is double && value == value.truncateToDouble()),
      _ => true,
    };
