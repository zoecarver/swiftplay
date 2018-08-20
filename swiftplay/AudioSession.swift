// Copyright 2017 Jenghis
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import AudioToolbox

public class AudioSession {
    
    private var callbackQueue = DispatchQueue(label: "CallbackQueue")
    
    private var playerState: PlayerState
    
    private var serverConfig = ServerConfig()
    
    init(withState state: PlayerState) {
        self.playerState = state
    }
    
    func start() {
        createAudioQueue(
            callbackQueue: callbackQueue) { (queue, buffer) in
                self.handleOutputBuffer(
                    playerState: self.playerState,
                    queue: queue,
                    buffer: buffer)
        }
        
        setMagicCookie(for: playerState.queue)
        createAudioBuffers(for: playerState.queue,
                           count: serverConfig.bufferCount)
    }
    
    func add(_ packet: Packet) {
        self.handlePacket(packet)
        print("packet handled")
    }
    
    func setSequenceNumber(_ sequenceNumber: UInt16) {
        callbackQueue.async {
            self.playerState.readIndex = sequenceNumber
            self.playerState.writeIndex = sequenceNumber
            self.playerState.packets = [Packet](repeating: Packet(), count: 1024)
        }
    }
    
    func pause() {
        guard let queue = playerState.queue else {
            print("Error: [pause] playeer state queue is nil")
            return
        }
        
        callbackQueue.async { self.playerState.isPlaying = false }
        AudioQueuePause(queue)
    }
    
    func reset() {
        guard let queue = playerState.queue else {
            print("Error: [reset] playeer state queue is nil")
            return
        }
        
        AudioQueueReset(queue)
    }
    
    func printDebugInfo() {
        #if DEBUG
        print(
            "Read: \(playerState.readIndex)",
            "Write: \(playerState.writeIndex)",
            "Diff: \(playerState.writeIndex &- playerState.readIndex)",
            "Buffers: \(playerState.buffers.count)"
        )
        #endif
    }
    
    private typealias AudioQueueCallback = AudioQueueOutputCallbackBlock
    
    private func createAudioQueue(callbackQueue: DispatchQueue,
                                  callback: @escaping AudioQueueCallback) {
        var format = createFormat()
        var queue: AudioQueueRef? = nil
        
        AudioQueueNewOutputWithDispatchQueue(
            &queue,
            &format,
            0,
            callbackQueue,
            callback)
        self.playerState.queue = queue
    }
    
    private func createFormat() -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        format.mSampleRate = StreamProperties.sampleRate
        format.mFormatID = StreamProperties.audioFormat
        format.mFramesPerPacket = StreamProperties.framesPerPacket
        format.mChannelsPerFrame = StreamProperties.channelsPerFrame
        return format
    }
    
    private func setMagicCookie(for queue: AudioQueueRef) {
        let magicCookie = Data(base64Encoded: StreamProperties.magicCookie)!
        _ = magicCookie.withUnsafeBytes {
            AudioQueueSetProperty(queue, kAudioQueueProperty_MagicCookie,
                                  $0, UInt32(magicCookie.count))
        }
    }
    
    private func createAudioBuffers(for queue: AudioQueueRef, count: Int) {
        let maxPacketSize = UInt32(serverConfig.bufferSize)
        let minPacketSize = UInt32(32)
        let numberOfPacketDescriptions = maxPacketSize / minPacketSize
        
        for _ in 0 ..< count {
            var buffer: AudioQueueBufferRef?
            
            AudioQueueAllocateBufferWithPacketDescriptions(
                queue,
                maxPacketSize,
                numberOfPacketDescriptions,
                &buffer)
            playerState.buffers.append(buffer!)
        }
    }
    
    private func handlePacket(_ packet: Packet) {
        let maxIndex = playerState.packets.count - 1
        let index = Int(packet.index) & maxIndex
        guard writePacket(packet, to: index) else { return }
        updateWriteIndex(with: packet)
        updatePlaybackStatus(with: packet)
    }
    
    private func writePacket(_ packet: Packet, to index: Int) -> Bool {
        let oldPacket = playerState.packets[index]
        let shouldOverwrite = checkPacket(packet, newerThan: oldPacket)
        guard shouldOverwrite else { return false }
        playerState.packets[index] = packet
        return true
    }
    
    private func checkPacket(_ packet: Packet,
                             newerThan oldPacket: Packet) -> Bool {
        
        let packetInterval = packet.index &- oldPacket.index
        let isPacketNewer = packetInterval < (1 << 15)
        
        return isPacketNewer
    }
    
    private func updateWriteIndex(with packet: Packet) {
        if packet.index &- playerState.writeIndex < (1 << 15) {
            playerState.writeIndex = packet.index
        }
    }
    
    private func updatePlaybackStatus(with packet: Packet) {
        let currentDelay = calculateDelay(for: packet)
        let hasEnoughPackets = currentDelay > StreamProperties.playbackDelay
        
        if true { handlePlayback() }
        print("playback handled")
        
        let hasAvailableBuffers = playerState.buffers.count > 0
        let hasIdleBuffers = playerState.isPlaying && hasAvailableBuffers
        
        if hasIdleBuffers { loadBuffers() }
    }
    
    private func loadBuffers() {
        guard let queue = playerState.queue else {
            print("Error: [load buffers] player state queue is nil")
            return
        }
        
        for _ in 0..<playerState.buffers.count {
            let buffer = playerState.buffers[0]
            
            handleOutputBuffer(
                playerState: playerState,
                queue: queue,
                buffer: buffer)
            
            playerState.buffers.removeFirst()
        }
    }
    
    private func calculateDelay(for packet: Packet) -> TimeInterval {
        let maxIndex = UInt16(playerState.packets.count - 1)
        let lastRead = Int(playerState.readIndex & maxIndex)
        let lastReadTimestamp = playerState.packets[lastRead].timeStamp
        let remainingTime = Double(packet.timeStamp &- lastReadTimestamp) / StreamProperties.sampleRate
        
        return remainingTime
    }
    
    private func handlePlayback() {
        if /*!playerState.isPlaying && manager.isPlaying*/ false {
            loadBuffers()
            playerState.isPlaying = true
            AudioQueueStart(playerState.queue, nil)
        }
        
        handleOutputBuffer(playerState: self.playerState, queue: playerState.queue, buffer: playerState.buffers[0])
        AudioQueueStart(playerState.queue, nil)
        print("playing")
    }
    
    private func handleOutputBuffer(playerState: PlayerState,
                                    queue: AudioQueueRef,
                                    buffer: AudioQueueBufferRef) {
        var packetCount = 0
        var offset = 0
        var playerState = self.playerState
        
        while hasAvailablePackets && playerState.isPlaying {
            let packet = currentPacket
            
            if !checkPacketIsSequential(packet) { continue }
            if !checkBufferHasSpace(for: packet, atOffset: offset) { break }
            
            writePacket(packet, to: buffer, index: packetCount, offset: offset)
            packetCount += 1
            offset += packet.data.count
            playerState.readIndex = playerState.readIndex &+ 1
        }
        
        buffer.pointee.mAudioDataByteSize = UInt32(offset)
        buffer.pointee.mPacketDescriptionCount = UInt32(packetCount)
        enqueueBuffer(buffer, to: queue)
    }
    
    private var hasAvailablePackets: Bool {
        return (playerState.writeIndex &- playerState.readIndex > 0) && playerState.packets.count > 0
    }
    
    private var currentPacket: Packet {
        let maxIndex = UInt16(playerState.packets.count - 1)
        let packetIndex = Int(playerState.readIndex & maxIndex)
        return playerState.packets[packetIndex]
    }
    
    private func checkPacketIsSequential(_ packet: Packet) -> Bool {
        if packet.index != playerState.readIndex {
            print("Skip: \(packet.index)",
                "Index: \(playerState.readIndex)")

            playerState.readIndex = playerState.readIndex &+ 1
            return false
        }
        return true
    }
    
    private func checkBufferHasSpace(for packet: Packet,
                                     atOffset offset: Int) -> Bool {
        let packetSize = packet.data.count
        return offset + packetSize <= serverConfig.bufferSize
    }
    
    private func writePacket(_ packet: Packet,
                             to buffer: AudioQueueBufferRef,
                             index: Int, offset: Int) {
        let packetSize = packet.data.count
        
        packet.data.withUnsafeBytes {
            buffer.pointee.mAudioData.advanced(by: offset).copyMemory(
                from: $0, byteCount: packetSize)
        }
        
        let packetDescriptions = buffer.pointee.mPacketDescriptions
        
        packetDescriptions?[index].mStartOffset = Int64(offset)
        packetDescriptions?[index].mDataByteSize = UInt32(packetSize)
        packetDescriptions?[index].mVariableFramesInPacket = 0
    }
    
    private func enqueueBuffer(_ buffer: AudioQueueBufferRef,
                               to queue: AudioQueueRef) {
        let error = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        if error != 0 {
            handleEnqueueError(for: buffer, in: queue, errorCode: Int(error))
        }
    }
    
    private func handleEnqueueError(for buffer: AudioQueueBufferRef,
                                    in queue: AudioQueueRef,
                                    errorCode: Int? = nil) {
        // Make buffer available for reuse
        playerState.buffers.append(buffer)
        let hasAvailableBuffer = (playerState.buffers.count < serverConfig.bufferCount)
        
        if !hasAvailableBuffer { resetPlaybackState(for: queue) }
        
        printDebugInfo()
        
        if errorCode != nil { print("Enqueue error: \(errorCode!)") }
    }
    
    private func resetPlaybackState(for queue: AudioQueueRef) {
        playerState.isPlaying = false
        AudioQueuePause(queue)
        playerState.readIndex = playerState.writeIndex
    }
}

// Properties are constant for AirPlay audio streams
private enum StreamProperties {
    static let audioFormat = kAudioFormatAppleLossless
    static let sampleRate = 44100.0
    static let framesPerPacket: UInt32 = 352
    static let channelsPerFrame: UInt32 = 2
    static let playbackDelay = 2.0
    static let magicCookie = "AAABYAAQKAoOAgD/AAAAAAAAAAAAAKxE"
}


