#!/bin/bash

echo "libraries:"

while read line; do
  if [[ $line != \#* ]] && [[ $line != "" ]]; then
    name=$(echo $line | awk -F'==' '{print $1}')
    version=$(echo $line | awk -F'==' '{print $2}')
    echo "  - name: $name"
    echo "    version: $version"
  fi
done < ./requirements.txt
