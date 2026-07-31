#!/bin/zsh
set -e

/usr/bin/defaults write com.apple.finder AppleShowAllFiles -bool true
/usr/bin/killall Finder

echo "Скрытые файлы теперь отображаются."
