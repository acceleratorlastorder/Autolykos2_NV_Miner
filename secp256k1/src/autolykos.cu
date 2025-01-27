// autolykos.cu

/*******************************************************************************

    AUTOLYKOS -- Autolykos puzzle cycle

*******************************************************************************/

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#endif

#include "../include/cryptography.h"
#include "../include/definitions.h"
#include "../include/easylogging++.h"
#include "../include/jsmn.h"
#include "../include/mining.h"
#include "../include/prehash.h"
#include "../include/processing.h"
#include "../include/reduction.h"
#include "../include/request.h"
#include "../include/httpapi.h"
#include "../include/queue.h"
#include "../include/cpuAutolykos.h"
#include <ctype.h>
#include <cuda.h>
#include <curl/curl.h>
#include <inttypes.h>
#include <iostream>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <vector>
#include <random>

#ifdef _WIN32
#include <io.h>
#define R_OK 4
#define W_OK 2
#define F_OK 0
#define access _access
#else
#include <unistd.h>
#endif

INITIALIZE_EASYLOGGINGPP

using namespace std::chrono;

std::atomic<int> end_jobs(0);

void SenderThread(info_t *info, BlockQueue<MinerShare> *shQueue)
{
    el::Helpers::setThreadName("sender thread");
    while (true)
    {
        MinerShare share = shQueue->get();
        LOG(INFO) << "Some GPU found and trying to POST a share: ";
        PostPuzzleSolution(info->to, (uint8_t *)&share.nonce);
    }
}

////////////////////////////////////////////////////////////////////////////////
//  Miner thread cycle
////////////////////////////////////////////////////////////////////////////////
void MinerThread(const int totalGPUCards, int deviceId, info_t *info, std::vector<double> *hashrates, std::vector<int> *tstamps, BlockQueue<MinerShare> *shQueue)
{
    AutolykosAlg solVerifier;
    CUDA_CALL(cudaSetDevice(deviceId));
    cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
    char threadName[20];
    sprintf(threadName, "GPU %i miner", deviceId);
    el::Helpers::setThreadName(threadName);

    state_t state = STATE_KEYGEN;

    //========================================================================//
    //  Host memory allocation
    //========================================================================//
    // CURL http request
    json_t request(0, REQ_LEN);

    // hash context
    // (212 + 4) bytes
    //ctx_t ctx_h;

    // autolykos variables
    uint8_t bound_h[NUM_SIZE_8];
    uint8_t mes_h[NUM_SIZE_8];
    uint8_t nonce[NONCE_SIZE_8];

    char to[MAX_URL_SIZE];

    // thread info variables
    uint_t blockId = 0;
    milliseconds start;

    //========================================================================//
    //  Copy from global to thread local data
    //========================================================================//
    info->info_mutex.lock();

    memcpy(mes_h, info->mes, NUM_SIZE_8);
    memcpy(bound_h, info->bound, NUM_SIZE_8);
    memcpy(to, info->to, MAX_URL_SIZE * sizeof(char));
    // blockId = info->blockId.load();
    //keepPrehash = info->keepPrehash;

    info->info_mutex.unlock();
    //========================================================================//
    //  Check GPU memory
    //========================================================================//
    size_t freeMem;
    size_t totalMem;

    CUDA_CALL(cudaMemGetInfo(&freeMem, &totalMem));

    if (freeMem < MIN_FREE_MEMORY)
    {
        LOG(ERROR) << "Not enough GPU memory for mining,"
                   << " minimum 2.8 GiB needed";

        return;
    }

    //========================================================================//
    //  Device memory allocation
    //========================================================================//
    // LOG(INFO) << "GPU " << deviceId << " allocating memory";

    // height for puzzle
    uint32_t *height_d;
    CUDA_CALL(cudaMalloc(&height_d, HEIGHT_SIZE));

    uint32_t *data_d;
    CUDA_CALL(cudaMalloc(&data_d, NUM_SIZE_8 + sizeof(ctx_t)));

    uint32_t *BHashes;
    CUDA_CALL(cudaMalloc(&BHashes, (NUM_SIZE_8)*THREADS_PER_ITER));

    // precalculated hashes
    // N_LEN * NUM_SIZE_8 bytes // 2 GiB
    uint32_t *hashes_d;
    CUDA_CALL(cudaMalloc(&hashes_d, (uint32_t)N_LEN * NUM_SIZE_8));
    //LOG(INFO) << "g" << LocalgpuId << " hashes_d: " << hashes_d <<  " ghashes_d[gpuId]: " << ghashes_d[gpuId];

    // place to handle result of the puzzle
    uint32_t *indices_d;
    CUDA_CALL(cudaMalloc(&indices_d, MAX_SOLS * sizeof(uint32_t)));

    // place to handle nonce if solution is found
    uint32_t indices_h[MAX_SOLS];

    uint32_t *count_d;

    CUDA_CALL(cudaMalloc(&count_d, sizeof(uint32_t)));

    CUDA_CALL(cudaMemset(count_d, 0, sizeof(uint32_t)));

    CUDA_CALL(cudaMemset(indices_d, 0, sizeof(uint32_t) * MAX_SOLS));

    //========================================================================//
    //  Autolykos puzzle cycle
    //========================================================================//
    uint64_t base = 0;
    uint64_t EndNonce = 0;
    uint32_t height = 0;

    int cntCycles = 0;
    int NCycles = 50;

    // wait for the very first block to come before starting
    while (info->blockId.load() == 0)
    {
    }

    start = duration_cast<milliseconds>(system_clock::now().time_since_epoch());

    do
    {
        ++cntCycles;
        if (!(cntCycles % NCycles))
        {
            milliseconds timediff = duration_cast<milliseconds>(
                                        system_clock::now().time_since_epoch()) -
                                    start;

            // change avg hashrate in global memory

            (*hashrates)[deviceId] = (double)NONCES_PER_ITER * (double)NCycles / ((double)1000 * timediff.count());

            start = duration_cast<milliseconds>(
                system_clock::now().time_since_epoch());

            (*tstamps)[deviceId] = start.count();
        }

        // if solution was found by this thread wait for new block to come
        if (state == STATE_KEYGEN)
        {
            while (info->blockId.load() == blockId)
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }

            state = STATE_CONTINUE;
        }

        // if proxy is disconnected  wait for connection
        while (!info->doJob)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));

            //			LOG(INFO) << "GPU " << deviceId << " problem in proxy ";
        }

        uint_t controlId = info->blockId.load();

        if (blockId != controlId)
        {
            // if info->blockId changed
            // read new message and bound to thread-local mem
            info->info_mutex.lock();

            memcpy(mes_h, info->mes, NUM_SIZE_8);
            memcpy(bound_h, info->bound, NUM_SIZE_8);

            //divide nonces between gpus
            memcpy(&EndNonce, info->extraNonceEnd, NONCE_SIZE_8);
            memcpy(&base, info->extraNonceStart, NONCE_SIZE_8);
            uint64_t nonceChunk = 1 + (EndNonce - base) / totalGPUCards;
            base = *((uint64_t *)info->extraNonceStart) + deviceId * nonceChunk;
            EndNonce = base + nonceChunk;

            //LOG(INFO) << "gpu: " << deviceId << " base: " << base << " end: " << EndNonce;

            memcpy(&height, info->Hblock, HEIGHT_SIZE);

            info->info_mutex.unlock();

            //LOG(INFO) << "GPU " << deviceId << " read new block data";
            blockId = controlId;

            VLOG(1) << "Generated new keypair,"
                    << " copying new data in device memory now";

            // copy message
            CUDA_CALL(cudaMemcpy(
                ((uint8_t *)data_d), mes_h, NUM_SIZE_8,
                cudaMemcpyHostToDevice));

            VLOG(1) << "Starting prehashing with new block data";

            Prehash(hashes_d, height);
            // calculate unfinalized hash of message
            VLOG(1) << "Starting InitMining";
            //InitMining(&ctx_h, (uint32_t *)mes_h, NUM_SIZE_8);

            LOG(INFO) << "GPU " << deviceId << " started";

            //cpyCtxSymbol((ctx_t*)(&ctx_h));
            cpyBSymbol(bound_h);

            CUDA_CALL(cudaDeviceSynchronize());
            state = STATE_CONTINUE;
        }

        //LOG(INFO) << "Starting main BlockMining procedure";

        // calculate solution candidates
        VLOG(1) << "Starting main BlockMining procedure";
        BlockMiningStep1<<<1 + (THREADS_PER_ITER - 1) / (BLOCK_DIM * 4), BLOCK_DIM>>>(data_d, base, hashes_d, BHashes);
        BlockMiningStep2<<<1 + (THREADS_PER_ITER - 1) / BLOCK_DIM, BLOCK_DIM>>>(data_d, base, height, hashes_d, indices_d, count_d, BHashes);
        VLOG(1) << "Trying to find solution";

        // restart iteration if new block was found
        if (blockId != info->blockId.load())
        {
            continue;
        }

        CUDA_CALL(cudaMemcpy(
            indices_h, indices_d, MAX_SOLS * sizeof(uint32_t),
            cudaMemcpyDeviceToHost));

        // solution found
        if (indices_h[0])
        {

            int i = 0;
            while (indices_h[i] && (i < 16 /*MAX_SOLS*/))
            {
                if (!info->stratumMode && i != 0)
                {
                    break;
                }

                *((uint64_t *)nonce) = base + indices_h[i] - 1;
                uint64_t endNonceT;
                memcpy(&endNonceT, info->extraNonceEnd, sizeof(uint64_t));
                if ((*((uint64_t *)nonce)) <= endNonceT)
                {
                    //LOG(INFO) << "sol check i: " << i << " sol index: "<< indices_h[i];
                    bool checksol = solVerifier.RunAlg(info->mes, nonce, info->bound, info->Hblock);
                    if (checksol)
                    {
                        MinerShare share(*((uint64_t *)nonce));
                        shQueue->put(share);

                        if (!info->stratumMode)
                        {
                            state = STATE_KEYGEN;
                            //end_jobs.fetch_add(1, std::memory_order_relaxed);
                            break;
                        }
                    }
                    else
                    {
                        LOG(INFO) << " problem in verify solution, nonce: " << *((uint64_t *)nonce);
                        //exit(0);
                    }
                }
                else
                {
                    LOG(INFO) << "nonce greater than end nonce, nonce: " << *((uint64_t *)nonce) << " endNonce:  " << endNonceT;
                }
                i++;
            }

            memset(indices_h, 0, MAX_SOLS * sizeof(uint32_t));
            CUDA_CALL(cudaMemset(
                indices_d, 0, MAX_SOLS * sizeof(uint32_t)));
            CUDA_CALL(cudaMemset(count_d, 0, sizeof(uint32_t)));
        }
        base += NONCES_PER_ITER;
        if (base > EndNonce) //end work
        {
            state = STATE_KEYGEN;
            end_jobs.fetch_add(1, std::memory_order_relaxed);
        }

    } while (1);
}

////////////////////////////////////////////////////////////////////////////////
//  Main
////////////////////////////////////////////////////////////////////////////////
int main(int argc, char **argv)
{
    /**************************************************************************
     *  Get conf files
     **************************************************************************/
    char confName[14] = "config.json";
    char *fileName = (argc > 0) ? confName : argv[1];

    /** TODO: add argument flag ex: -logconf log.conf*/
    bool haslog = (argc > 1);

    //========================================================================//
    //  Setup log
    //========================================================================//

    if (haslog)
    {
        char *logFile = argv[2];
        
        // Load configuration from file
        el::Configurations conf(logFile);
        // Reconfigure single logger
        el::Loggers::reconfigureLogger("default", conf);
        // Actually reconfigure all loggers instead
        el::Loggers::reconfigureAllLoggers(conf);
        // Now all the loggers will use configuration from file

        LOG(INFO) << "got file: " << logFile;
    }
    else
    {
        START_EASYLOGGINGPP(argc, argv);
        el::Loggers::reconfigureAllLoggers(el::ConfigurationType::Format, "%datetime %level [%thread] %msg");
        LOG(INFO) << "using default logging conf: ";
    }

    el::Helpers::setThreadName("main thread");

    //========================================================================//
    //  Check GPU availability
    //========================================================================//
    int deviceCount;
    int status = EXIT_SUCCESS;

    if (cudaGetDeviceCount(&deviceCount) != cudaSuccess)
    {
        LOG(ERROR) << "Error checking GPU";
        return EXIT_FAILURE;
    }
    LOG(INFO) << "Using " << deviceCount << " GPU devices";

    //========================================================================//
    //  Read configuration file
    //========================================================================//
    char from[MAX_URL_SIZE];
    info_t info;
    info.blockId = 0;
    info.keepPrehash = 0;

    BlockQueue<MinerShare> solQueue;

    LOG(INFO) << "Using configuration file " << fileName;

    // check access to config file
    if (access(fileName, F_OK) == -1)
    {
        LOG(ERROR) << "Configuration file " << fileName << " is not found";
        return EXIT_FAILURE;
    }

    // read configuration from file
    status = ReadConfig(
        fileName, from, info.to, info.endJob);

    if (status == EXIT_FAILURE)
    {
        return EXIT_FAILURE;
    }

    LOG(INFO) << "Block getting URL:\n   " << from;
    LOG(INFO) << "Solution posting URL:\n   " << info.to;

    //========================================================================//
    //  Setup CURL
    //========================================================================//
    // CURL http request
    json_t request(0, REQ_LEN);

    // CURL init
    PERSISTENT_CALL_STATUS(curl_global_init(CURL_GLOBAL_ALL), CURLE_OK);

    //========================================================================//
    //  Fork miner threads
    //========================================================================//
    std::vector<std::thread> miners(deviceCount);
    std::vector<double> hashrates(deviceCount);
    std::vector<int> lastTimestamps(deviceCount);
    std::vector<int> timestamps(deviceCount);

    // PCI bus and device IDs
    std::vector<std::pair<int, int>> devinfos(deviceCount);
    for (int i = 0; i < deviceCount; ++i)
    {
        cudaDeviceProp props;
        if (cudaGetDeviceProperties(&props, i) == cudaSuccess)
        {
            devinfos[i] = std::make_pair(props.pciBusID, props.pciDeviceID);
        }
        miners[i] = std::thread(MinerThread, deviceCount, i, &info, &hashrates, &timestamps, &solQueue);
        hashrates[i] = 0;
        lastTimestamps[i] = 1;
        timestamps[i] = 0;
    }

    // get first block
    status = EXIT_FAILURE;
    while (status != EXIT_SUCCESS)
    {
        status = GetLatestBlock(from, &request, &info, 0);
        std::this_thread::sleep_for(std::chrono::milliseconds(800));
        if (status != EXIT_SUCCESS)
        {
            LOG(INFO) << "Waiting for block data to be published by node...";
        }
    }
    std::thread solSender(SenderThread, &info, &solQueue);
    std::thread httpApi = std::thread(HttpApiThread, &hashrates, &devinfos);

    //========================================================================//
    //  Main thread get-block cycle
    //========================================================================//
    uint_t curlcnt = 0;
    const uint_t curltimes = 1000;

    milliseconds ms = milliseconds::zero();

    // bomb node with HTTP with 10ms intervals, if new block came
    // signal miners with blockId
    while (1)
    {
        milliseconds start = duration_cast<milliseconds>(
            system_clock::now().time_since_epoch());

        // get latest block
        status = GetLatestBlock(from, &request, &info, 0);

        if (status != EXIT_SUCCESS)
        {
            LOG(INFO) << "Getting block error";
        }

        ms += duration_cast<milliseconds>(
                  system_clock::now().time_since_epoch()) -
              start;

        ++curlcnt;

        if (!(curlcnt % curltimes))
        {
            LOG(INFO) << "Average curling time "
                      << ms.count() / (double)curltimes << " ms";
            LOG(INFO) << "Current block candidate: " << request.ptr;
            ms = milliseconds::zero();
            std::stringstream hrBuffer;
            hrBuffer << "Average hashrates: ";
            double totalHr = 0;
            for (int i = 0; i < deviceCount; ++i)
            {
                // check if miner thread is updating hashrate, e.g. alive
                if (!(curlcnt % (5 * curltimes)))
                {
                    if (lastTimestamps[i] == timestamps[i])
                    {
                        hashrates[i] = 0;
                    }
                    lastTimestamps[i] = timestamps[i];
                }
                hrBuffer << "GPU" << i << " " << hashrates[i] << " MH/s ";
                totalHr += hashrates[i];
            }
            hrBuffer << "Total " << totalHr << " MH/s ";
            LOG(INFO) << hrBuffer.str();
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(100));

        int completeMiners = end_jobs.load();
        if (completeMiners >= deviceCount)
        {
            end_jobs.store(0);
            JobCompleted(info.endJob);
        }
    }

    return EXIT_SUCCESS;
}

// autolykos.cu