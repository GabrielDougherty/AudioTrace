#pragma once

#include <atomic>
#include <memory>
#include <cstddef>
#include <cstring>

namespace AudioTrace {

/// Lock-free single-producer single-consumer ring buffer
/// Safe for use in realtime audio contexts
template <typename T>
class RingBuffer {
public:
    explicit RingBuffer(size_t capacity)
        : capacity_(capacity + 1)  // +1 for distinguishing empty vs full
        , buffer_(std::make_unique<T[]>(capacity_))
        , write_pos_(0)
        , read_pos_(0)
    {}

    RingBuffer(const RingBuffer&) = delete;
    RingBuffer& operator=(const RingBuffer&) = delete;

    /// Write single element (producer only)
    /// Returns true if written, false if buffer full
    bool push(const T& item) noexcept {
        const size_t current_write = write_pos_.load(std::memory_order_relaxed);
        const size_t next_write = (current_write + 1) % capacity_;
        
        if (next_write == read_pos_.load(std::memory_order_acquire)) {
            return false;  // Buffer full
        }
        
        buffer_[current_write] = item;
        write_pos_.store(next_write, std::memory_order_release);
        return true;
    }

    /// Read single element (consumer only)
    /// Returns true if read, false if buffer empty
    bool pop(T& item) noexcept {
        const size_t current_read = read_pos_.load(std::memory_order_relaxed);
        
        if (current_read == write_pos_.load(std::memory_order_acquire)) {
            return false;  // Buffer empty
        }
        
        item = buffer_[current_read];
        read_pos_.store((current_read + 1) % capacity_, std::memory_order_release);
        return true;
    }

    /// Check available space (approximate, for diagnostics only)
    size_t available_read() const noexcept {
        const size_t write = write_pos_.load(std::memory_order_acquire);
        const size_t read = read_pos_.load(std::memory_order_acquire);
        
        if (write >= read) {
            return write - read;
        }
        return capacity_ - read + write;
    }

    size_t capacity() const noexcept { return capacity_ - 1; }

private:
    const size_t capacity_;
    std::unique_ptr<T[]> buffer_;
    std::atomic<size_t> write_pos_;
    std::atomic<size_t> read_pos_;
};

}  // namespace AudioTrace
