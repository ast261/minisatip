set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR sh4)

set(TOOLCHAIN_DIR /home/axel/sync/software/satip-axe/toolchain/sh4-linux/sh4-idl4k-linux-gnu_sdk-buildroot)

set(CMAKE_CXX_COMPILER ${TOOLCHAIN_DIR}/bin/sh4-idl4k-linux-gnu-g++)
set(CMAKE_C_COMPILER   ${TOOLCHAIN_DIR}/bin/sh4-idl4k-linux-gnu-gcc)

set(CMAKE_SYSROOT ${TOOLCHAIN_DIR}/sh4-idl4k-linux-gnu/sysroot)
set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
