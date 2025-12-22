#include "AudioTapManager.hpp"
#include <thread>
#include <algorithm>
#include <CoreFoundation/CoreFoundation.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>

namespace AudioTrace {

AudioTapManager::AudioTapManager(Config config)
    : config_(config)
{}

AudioTapManager::~AudioTapManager() {
    stop();
}

bool AudioTapManager::start() {
    if (is_running_) {
        return false;
    }

    // Create aggregate device
    if (!create_aggregate_device()) {
        return false;
    }

    // Start worker thread
    worker_should_stop_.store(false, std::memory_order_release);
    worker_thread_ = std::make_unique<std::thread>(
        &AudioTapManager::worker_thread_proc, this
    );

    // Register IOProc callback for aggregate device
    OSStatus status = AudioDeviceCreateIOProcID(
        aggregate_device_id_,
        audio_io_proc,
        this,
        &io_proc_id_
    );
    
    if (status != noErr) {
        stop();
        return false;
    }

    // Start the aggregate device
    status = AudioDeviceStart(aggregate_device_id_, io_proc_id_);
    if (status != noErr) {
        AudioDeviceDestroyIOProcID(aggregate_device_id_, io_proc_id_);
        io_proc_id_ = nullptr;
        stop();
        return false;
    }

    is_running_ = true;
    return true;
}

void AudioTapManager::stop() {
    if (!is_running_) {
        return;
    }

    // Stop audio device
    if (aggregate_device_id_ != kAudioObjectUnknown && io_proc_id_ != nullptr) {
        AudioDeviceStop(aggregate_device_id_, io_proc_id_);
        AudioDeviceDestroyIOProcID(aggregate_device_id_, io_proc_id_);
        io_proc_id_ = nullptr;
    }

    // Signal worker thread to stop
    worker_should_stop_.store(true, std::memory_order_release);
    
    if (worker_thread_ && worker_thread_->joinable()) {
        worker_thread_->join();
    }
    worker_thread_.reset();

    // Destroy aggregate device and taps
    destroy_aggregate_device();

    process_taps_.clear();
    is_running_ = false;
}

void AudioTapManager::set_audio_callback(AudioCallback callback) {
    audio_callback_ = std::move(callback);
}

std::vector<pid_t> AudioTapManager::get_tapped_processes() const {
    std::vector<pid_t> result;
    result.reserve(process_taps_.size());
    
    for (const auto& tap : process_taps_) {
        result.push_back(tap->pid);
    }
    
    return result;
}

void AudioTapManager::worker_thread_proc() {
    while (!worker_should_stop_.load(std::memory_order_acquire)) {
        bool did_work = false;

        for (auto& tap : process_taps_) {
            AudioTapData data;
            while (tap->ring_buffer.pop(data)) {
                if (audio_callback_) {
                    audio_callback_(data);
                }
                did_work = true;
            }
        }

        if (!did_work) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }
}

OSStatus AudioTapManager::audio_io_proc(
    AudioDeviceID,
    const AudioTimeStamp*,
    const AudioBufferList* inInputData,
    const AudioTimeStamp* inInputTime,
    AudioBufferList*,
    const AudioTimeStamp*,
    void* inClientData
) noexcept
{
    auto* manager = static_cast<AudioTapManager*>(inClientData);
    if (!manager || !inInputData) {
        return noErr;
    }

    manager->process_input_data(inInputData, inInputTime);
    
    return noErr;
}

void AudioTapManager::process_input_data(const AudioBufferList* buffer_list,
                                         const AudioTimeStamp* timestamp) noexcept
{
    if (!buffer_list || buffer_list->mNumberBuffers == 0) {
        return;
    }
    
    for (uint32_t i = 0; i < buffer_list->mNumberBuffers; ++i) {
        const AudioBuffer& buffer = buffer_list->mBuffers[i];
        
        if (buffer.mData == nullptr || buffer.mDataByteSize == 0) {
            continue;
        }

        const float* samples = static_cast<const float*>(buffer.mData);
        const uint32_t sample_count = buffer.mDataByteSize / sizeof(float);
        const uint32_t channel_count = buffer.mNumberChannels;
        const uint32_t frame_count = sample_count / channel_count;

        for (auto& tap : process_taps_) {
            AudioTapData data;
            data.pid = tap->pid;
            data.frame_count = frame_count;
            data.channel_count = channel_count;
            data.sample_time = timestamp ? timestamp->mSampleTime : 0;
            
            const size_t copy_size = std::min(static_cast<size_t>(sample_count), tap->temp_buffer.size());
            std::copy_n(samples, copy_size, tap->temp_buffer.begin());
            data.samples = tap->temp_buffer;
            
            tap->ring_buffer.push(data);
        }
    }
}

AudioStreamBasicDescription AudioTapManager::get_stream_format() const {
    AudioStreamBasicDescription format{};
    format.mSampleRate = config_.sample_rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = 2;
    format.mBytesPerFrame = format.mChannelsPerFrame * sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = format.mBytesPerFrame;
    return format;
}

bool AudioTapManager::create_aggregate_device() {
    CFMutableDictionaryRef device_dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    
    if (!device_dict) {
        return false;
    }

    CFStringRef device_name = CFSTR("AudioTrace Tap Aggregate");
    CFDictionarySetValue(device_dict, CFSTR(kAudioAggregateDeviceNameKey), device_name);
    
    CFStringRef device_uid = CFSTR("com.audiotrace.aggregate");
    CFDictionarySetValue(device_dict, CFSTR(kAudioAggregateDeviceUIDKey), device_uid);

    OSStatus status = AudioHardwareCreateAggregateDevice(device_dict, &aggregate_device_id_);
    CFRelease(device_dict);
    
    return (status == noErr && aggregate_device_id_ != kAudioObjectUnknown);
}

void AudioTapManager::destroy_aggregate_device() {
    if (aggregate_device_id_ != kAudioObjectUnknown) {
        for (auto& tap : process_taps_) {
            if (tap->tap_id != kAudioObjectUnknown) {
                AudioHardwareDestroyProcessTap(tap->tap_id);
            }
        }
        
        AudioHardwareDestroyAggregateDevice(aggregate_device_id_);
        aggregate_device_id_ = kAudioObjectUnknown;
    }
}

bool AudioTapManager::create_tap_for_process(pid_t pid) {
    @autoreleasepool {
        // Create array of process AudioObjectIDs
        NSNumber* processID = @(pid);
        NSArray<NSNumber*>* processes = @[processID];
        
        // Create tap description (stereo mixdown of this process)
        CATapDescription* tapDesc = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
        if (!tapDesc) {
            return false;
        }
        
        // Set mute behavior (don't mute original audio)
        tapDesc.muteBehavior = CATapUnmuted;
        
        // Create the tap
        AudioObjectID tap_id = kAudioObjectUnknown;
        OSStatus status = AudioHardwareCreateProcessTap(tapDesc, &tap_id);
        
        if (status != noErr || tap_id == kAudioObjectUnknown) {
            return false;
        }

        // Add tap to aggregate device
        if (!add_tap_to_aggregate(tap_id)) {
            AudioHardwareDestroyProcessTap(tap_id);
            return false;
        }

        // Create ProcessTap structure
        size_t buffer_size = config_.buffer_frames * 2;
        auto process_tap = std::make_unique<ProcessTap>(
            pid,
            tap_id,
            config_.ringbuffer_capacity,
            buffer_size
        );
        
        process_taps_.push_back(std::move(process_tap));
        return true;
    }
}

bool AudioTapManager::add_tap_to_aggregate(AudioObjectID tap_id) {
    CFStringRef tap_uid = nullptr;
    UInt32 data_size = sizeof(tap_uid);
    AudioObjectPropertyAddress prop_addr{
        kAudioTapPropertyUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    
    OSStatus status = AudioObjectGetPropertyData(
        tap_id,
        &prop_addr,
        0,
        nullptr,
        &data_size,
        &tap_uid
    );
    
    if (status != noErr || !tap_uid) {
        return false;
    }

    CFStringRef uid_array[] = { tap_uid };
    CFArrayRef taps = CFArrayCreate(
        kCFAllocatorDefault,
        (const void**)uid_array,
        1,
        &kCFTypeArrayCallBacks
    );
    
    if (!taps) {
        CFRelease(tap_uid);
        return false;
    }

    AudioObjectPropertyAddress tap_list_addr{
        kAudioAggregateDevicePropertyTapList,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    
    data_size = sizeof(CFArrayRef);
    status = AudioObjectSetPropertyData(
        aggregate_device_id_,
        &tap_list_addr,
        0,
        nullptr,
        data_size,
        &taps
    );
    
    CFRelease(taps);
    CFRelease(tap_uid);
    
    return status == noErr;
}

}  // namespace AudioTrace
