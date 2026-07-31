#!/bin/zsh
set -e

/usr/bin/open -g -b ee.antero.apps
/bin/sleep 1
/usr/bin/notifyutil -p ee.antero.apps.hide-hidden

echo "Скрытые файлы скрыты без перезапуска Finder."
