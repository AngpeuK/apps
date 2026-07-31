#!/bin/zsh
set -e

/usr/bin/defaults write com.apple.finder AppleShowAllFiles -bool false
/usr/bin/killall Finder

echo "Скрытые файлы снова скрыты."
