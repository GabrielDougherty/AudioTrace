#include "Logger.hpp"

namespace AudioTrace {

quill::Logger* Logger::logger_ = nullptr;
bool Logger::initialized_ = false;

}  // namespace AudioTrace
