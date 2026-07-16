#pragma once

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace theia::io_detail {

inline std::string errnoMessage(int value) {
    const char* message = std::strerror(value);
    return message ? std::string(message) : std::string("unknown I/O error");
}

// Complete a stdio write without losing errors buffered until flush/close.
// Every caller owns `file` and transfers that ownership to this function.
inline bool finishFileWrite(FILE* file, bool payloadWritten,
                            const char* label,
                            const char* payloadFailure,
                            std::string& error) {
    const int flushResult = std::fflush(file);
    const int flushErrno = flushResult == 0 ? 0 : errno;
    const int closeResult = std::fclose(file);
    const int closeErrno = closeResult == 0 ? 0 : errno;

#ifndef NDEBUG
    const bool injectedCloseFailure =
        std::getenv("THEIA_TEST_FAIL_DURABLE_CLOSE") != nullptr;
#else
    constexpr bool injectedCloseFailure = false;
#endif

    if (!payloadWritten) {
        error = std::string(label) + ": " + payloadFailure;
        return false;
    }
    if (flushResult != 0) {
        error = std::string(label) + ": flush failed: " +
                errnoMessage(flushErrno);
        return false;
    }
    if (closeResult != 0) {
        error = std::string(label) + ": close failed: " +
                errnoMessage(closeErrno);
        return false;
    }
    if (injectedCloseFailure) {
        error = std::string(label) +
                ": injected durable-close failure";
        return false;
    }
    return true;
}

} // namespace theia::io_detail
