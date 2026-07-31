#!/bin/zsh
set -e

/usr/bin/open -g -b ee.antero.apps
/bin/sleep 1
/usr/bin/notifyutil -p ee.antero.apps.show-hidden

echo "Скрытые файлы отображаются без перезапуска Finder."
