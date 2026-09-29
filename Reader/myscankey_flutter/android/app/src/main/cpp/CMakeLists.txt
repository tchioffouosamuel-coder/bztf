cmake_minimum_required(VERSION 3.22.1)
project(bibliorfid_desk_reader C)

# Nom imposé par reader.jar : System.loadLibrary("SerialPort").
add_library(SerialPort SHARED SerialPort.c)
find_library(log-lib log)
target_link_libraries(SerialPort ${log-lib})
