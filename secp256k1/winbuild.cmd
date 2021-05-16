SET "OPENSSL_DIR=C:\OpenSSL-Win64"
SET "LIBCURL_DIR=REPLACE_WITH_LIBCURL_FOLDER"
SET "CUDA_COMPUTE_ARCH=61"
SET "BLOCK_DIM=64"
SET "WORKSPACE=0x800000"
cd src
 
::"c:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat"
 
nvcc -use_fast_math -maxrregcount=128 -o ../builds/miner.exe -Xcompiler "/std:c++14" ^
    -gencode=arch=compute_%CUDA_COMPUTE_ARCH%,code=\"sm_%CUDA_COMPUTE_ARCH%,compute_%CUDA_COMPUTE_ARCH%\"^
    -DBLOCK_DIM=%BLOCK_DIM% -DNONCES_PER_ITER=%WORKSPACE%^
    -I %OPENSSL_DIR%\include ^
    -I %LIBCURL_DIR%\include ^
    -l %LIBCURL_DIR%\lib\libcurl ^
    -l %OPENSSL_DIR%\lib\libeay32 -L %OPENSSL_DIR%/lib ^
    -lnvml ^
    cpuAutolykos.cc conversion.cc cryptography.cc definitions.cc jsmn.c httpapi.cc ^
    mining.cu prehash.cu processing.cc request.cc easylogging++.cc autolykos.cu httplib.cc

cd ..
::SET PATH=%PATH%;C:\Program Files\NVIDIA Corporation\NVSMI



