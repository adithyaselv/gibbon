#!/bin/bash

set +e

function checkfile() {
    if ! [ -e "$1" ]; then
        echo "File does not exist, cannot diff!: " $1
        exit 1
    fi
}

checkfile $1
checkfile $2

A=`mktemp`
B=`mktemp`

grep -v SELFTIMED $1 | grep -v BATCHTIME > $A
grep -v SELFTIMED $2 | grep -v BATCHTIME > $B

diff $A $B
code=$?

rm $A $B

if [ "$code" == "0" ]; then
    #    echo "  -> Success.";
    exit $code;
else
    echo "ERROR: Answers differed!: diff $1  $2";
    exit $code;
fi