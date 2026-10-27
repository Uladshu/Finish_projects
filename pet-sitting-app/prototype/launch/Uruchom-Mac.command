#!/bin/bash
# Pupil Obok - local test server for Mac/Linux. Serves this folder at http://localhost:8000. Close the window (Ctrl+C) to stop.
cd "$(dirname "$0")"
PORT=8000
while lsof -i :$PORT >/dev/null 2>&1; do PORT=$((PORT+1)); done
URL="http://localhost:$PORT"
echo ""; echo "  Pupil Obok dziala: $URL"; echo "  Zostaw to okno otwarte. Ctrl+C lub zamkniecie okna zatrzymuje strone."; echo ""
( sleep 1; (command -v open >/dev/null && open "$URL") || (command -v xdg-open >/dev/null && xdg-open "$URL") ) >/dev/null 2>&1 &
if command -v python3 >/dev/null; then exec python3 -m http.server $PORT --bind 127.0.0.1
elif command -v ruby >/dev/null; then exec ruby -run -e httpd . -p $PORT -b 127.0.0.1
elif command -v php >/dev/null; then exec php -S 127.0.0.1:$PORT
else echo "Brak python3/ruby/php. Zainstaluj Python ze strony python.org i uruchom ponownie."; read -r; fi
