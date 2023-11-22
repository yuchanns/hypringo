#!/bin/bash

cd "$(dirname "${BASH_SOURCE[0]}")" || exit

eval $(luarocks path)

lua ./main.lua
