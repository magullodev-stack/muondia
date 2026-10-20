# Explorador visual de Muondia

La extensión propia `magullodev.muondia-visual` aparece dentro del **Explorador** de VS Code como **MUONDIA · EXPLORADOR VISUAL**. Solo se activa en el repositorio Muondia.

Las pantallas, sus estados, archivos Dart e imágenes se declaran en `lib/development/experiences.json`. El árbol ACCESO → Authentication muestra la pantalla inicial, la vista de email y las cuatro imágenes correspondientes. Al pulsar una pantalla se abre su código Flutter; al pulsar una imagen se abre su vista en VS Code.

El **ojo** muestra u oculta cada imagen de forma reversible, conservando su geometría y sin borrarla. Solo cambia las constantes de `lib/development/visual_layers.dart`; las compilaciones de producción siguen mostrando todas las imágenes. Las modificaciones en Dart se actualizan en el emulador con Hot Reload.

**Sustituir imagen** conserva la primera versión original en `.muondia/visual-backups/`, excluida de Git. **Restaurar imagen original** la recupera; si el archivo PNG cambia, Flutter necesita reconstruir los recursos de la aplicación. No se borran imágenes desde el explorador.

Instalación local única desde PowerShell:

```powershell
& "C:\Users\Miquelet\repos\muondia\scripts\install-visual-explorer.ps1"
```

Tras instalar, recarga la ventana de VS Code con **Developer: Reload Window**. La extensión usa el proyecto del repositorio y no inicia otro emulador, otra sesión Flutter ni tareas Git.
