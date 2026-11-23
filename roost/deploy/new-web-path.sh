#!/usr/bin/env sh
# Prints a random, unguessable path for the web app, e.g. /h/9f3c1a7e2b/
printf '/h/%s/\n' "$(head -c 5 /dev/urandom | od -An -tx1 | tr -d ' \n')"
