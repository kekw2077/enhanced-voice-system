# Тема EVS для VS Code

Две темы в палитре прототипа: **EVS Dark** (#07080C, акцент #7F5AAC) и **EVS Light** (#EEF2F8).

## Поставить локально, без публикации

1. Скопируйте папку `vscode-theme` в каталог расширений:
   - Windows: `%USERPROFILE%\.vscode\extensions\evs-theme`
   - macOS/Linux: `~/.vscode/extensions/evs-theme`
2. Перезапустите VS Code.
3. `Ctrl+K Ctrl+T` → выберите **EVS Dark** или **EVS Light**.

## Собрать .vsix

```
npm i -g @vscode/vsce
cd vscode-theme
vsce package
code --install-extension evs-theme-1.0.0.vsix
```

## Дополнить под себя

Цвета берутся из `../tokens/tokens.json`. Если поменяете акцент приложения
(Аврора / Закат / Мята), поправьте в теме `#7F5AAC` на `a2` нужной тройки —
остальное останется согласованным.
