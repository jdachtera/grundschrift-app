#!/bin/bash
CURRENTDIR=$PWD
VERSION=$1
if [ -z "$VERSION" ]
  then
    VERSION=origin/master
fi

cd $(dirname $0)/phonegap
git reset --hard
git fetch
git checkout $VERSION
cd ..
rm -rf build/*
cd $CURRENTDIR
