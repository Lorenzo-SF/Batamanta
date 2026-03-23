#!/bin/bash

test(){
    rm -fr /tmp/batamant*
    rm -fr ~/.cache/batamanta
    rm -fr deps
    rm -fr _build
    rm -fr test_*-0.1.0-x86_64-linux
    mix deps.get
    mix batamanta 
}

cd test_cli 
test
./test_cli-0.1.0-x86_64-linux 
rm test_cli-0.1.0-x86_64-linux 


cd ../test_tui 
test
./test_tui-0.1.0-x86_64-linux
rm test_tui-0.1.0-x86_64-linux


cd ../test_daemon 
test
./test_escript-0.1.0-x86_64-linux 
rm test_escript-0.1.0-x86_64-linux 


cd ../test_escript 
test
./test_escript-0.1.0-x86_64-linux
rm test_escript-0.1.0-x86_64-linux
