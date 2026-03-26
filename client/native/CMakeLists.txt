cmake_minimum_required(VERSION 3.16)

set(CMAKE_C_STANDARD 17)
set(CMAKE_CXX_STANDARD 17)

project(claire_native LANGUAGES C CXX)

if (CMAKE_SYSTEM_NAME MATCHES "iOS" OR CMAKE_SYSTEM_NAME MATCHES "Darwin")
    enable_language(OBJCXX)
endif()

set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")

# Atria source tree (submodule)
set(ATRIA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../submodules/atria)
set(ATRIA_NATIVE_DIR ${ATRIA_DIR}/composeApp/native)
set(ATRIA_EMBEDDED_DIR ${ATRIA_NATIVE_DIR}/embedded)
set(ATRIA_SUBMODULES_DIR ${ATRIA_DIR}/submodules)

# ---- Submodule dependencies ----

# minimp3 (header-only)
include_directories(${ATRIA_SUBMODULES_DIR}/minimp3/)

# MelCodec
set(MELCODEC_DIR ${ATRIA_SUBMODULES_DIR}/MelCodec/C)
add_subdirectory(${MELCODEC_DIR} ./MelCodec-bin EXCLUDE_FROM_ALL)
include_directories(${MELCODEC_DIR})

# SegVox VAD
set(SEGVOX_DIR ${ATRIA_SUBMODULES_DIR}/SegVox/C)
add_subdirectory(${SEGVOX_DIR} ./SegVox-bin EXCLUDE_FROM_ALL)
include_directories(${SEGVOX_DIR})

# Oboe FIFO (thread-safe audio buffers)
set(OBOE_DIR ${ATRIA_SUBMODULES_DIR}/smpl_oboe/)
include_directories(${OBOE_DIR}/include ${OBOE_DIR}/src ${OBOE_DIR}/samples/shared)

# Opus OGG
set(OPUS_OGG_DIR ${ATRIA_SUBMODULES_DIR}/smpl_opus/opus_ogg)
set(OPUS_DIR ${ATRIA_SUBMODULES_DIR}/smpl_opus)
include_directories(${OPUS_OGG_DIR}/include ${OPUS_DIR}/include ${OPUS_DIR}/celt ${OPUS_DIR}/silk ${OPUS_DIR}/src)
add_subdirectory(${OPUS_OGG_DIR} ./opus_ogg-bin EXCLUDE_FROM_ALL)

# AFE (Audio Front End — echo cancellation, noise suppression)
set(AFE_DIR ${ATRIA_SUBMODULES_DIR}/AEC/c/SmplAfe/SmplAFELib)
include_directories(${AFE_DIR} ${AFE_DIR}/../../third_party/)
add_subdirectory(${AFE_DIR} ./afe-bin EXCLUDE_FROM_ALL)
target_compile_options(SmplAFELib PRIVATE "-w")

# Compressor
set(COMPRESSOR_DIR ${ATRIA_SUBMODULES_DIR}/Compressor/C)
add_subdirectory(${COMPRESSOR_DIR} ./compressor-bin EXCLUDE_FROM_ALL)
include_directories(${COMPRESSOR_DIR})

# PFFFT
set(PFFFT_DIR ${ATRIA_SUBMODULES_DIR}/pffft)
include_directories(${PFFFT_DIR})

# ---- Source files ----

set(CLAIRE_NATIVE_SOURCES
    # Core audio processing
    ${ATRIA_EMBEDDED_DIR}/SmplAudioProc.cpp
    ${ATRIA_EMBEDDED_DIR}/SmplResamplerF32.cpp
    ${ATRIA_EMBEDDED_DIR}/ResampleWrapper.cpp
    ${ATRIA_EMBEDDED_DIR}/SmplOpusWrapper.cpp
    ${ATRIA_EMBEDDED_DIR}/SmplFileDecoder.cpp
    ${ATRIA_EMBEDDED_DIR}/SmplTimeScale.cpp
    ${ATRIA_EMBEDDED_DIR}/whisper_tflite_mel.cpp

    # VAD + segmentation
    ${ATRIA_EMBEDDED_DIR}/SmplVadSegmentationBase.cpp
    ${ATRIA_EMBEDDED_DIR}/SmplVadSegmentation.cpp
    ${ATRIA_EMBEDDED_DIR}/SmplAfeVadSegmentation.cpp
    ${ATRIA_EMBEDDED_DIR}/SmplSegVoxVadSegmentation.cpp

    # Zipper SDK
    ${ATRIA_EMBEDDED_DIR}/zipperSdk/SmplZipperClientApi.cpp

    # Utilities
    ${ATRIA_EMBEDDED_DIR}/utils/DumpSignal.cpp
    ${ATRIA_EMBEDDED_DIR}/utils/wavefile.cpp
    ${ATRIA_EMBEDDED_DIR}/speex/resample.c
    ${PFFFT_DIR}/pffft.c

    # Oboe FIFO (needed for iOS too)
    ${OBOE_DIR}/src/fifo/FifoBuffer.cpp
    ${OBOE_DIR}/src/fifo/FifoController.cpp
    ${OBOE_DIR}/src/fifo/FifoControllerBase.cpp
    ${OBOE_DIR}/src/fifo/FifoControllerIndirect.cpp

    # iOS CoreAudio engine
    ${ATRIA_EMBEDDED_DIR}/ios/SmplCoreAudioEngine.mm
)

# Include embedded directory for headers
include_directories(${ATRIA_EMBEDDED_DIR})
include_directories(${ATRIA_EMBEDDED_DIR}/utils)
include_directories(${ATRIA_EMBEDDED_DIR}/zipperSdk)
include_directories(${ATRIA_EMBEDDED_DIR}/ios)

# Force Zipper SDK API to compile as ObjC++ on iOS (it includes ObjC headers)
set_source_files_properties(
    ${ATRIA_EMBEDDED_DIR}/zipperSdk/SmplZipperClientApi.cpp
    PROPERTIES LANGUAGE OBJCXX
)

# Build as static library
add_library(claire_native STATIC ${CLAIRE_NATIVE_SOURCES})

# Use Zipper SDK API mode (cleaner interface)
target_compile_definitions(claire_native PRIVATE SMPL_ZIPPER_SDK_BUILD=1)

# Link submodule libraries
target_link_libraries(claire_native PRIVATE
    SmplAFELib
    SmplOpusOgg
    SmplMelCodec
    SegVoxVad
    SmplCompressor
)

# Suppress warnings from third-party code
target_compile_options(claire_native PRIVATE "-w")
