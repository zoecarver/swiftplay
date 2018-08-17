//
//  Airplay.swift
//  swiftplay
//
//  Created by Zoe IAMZOE.io on 8/10/18.
//  Copyright © 2018 Zoe IAMZOE.io. All rights reserved.
//

import Foundation
import AudioToolbox
import CocoaAsyncSocket
import Security
import CommonCrypto

public let port: UInt16! = 6010

public class AirplayServer: NSObject, GCDAsyncSocketDelegate, GCDAsyncUdpSocketDelegate {
    
    public internal (set) var service: NetService?
    
    public internal (set) var tcpSockets: [GCDAsyncSocket]! = [GCDAsyncSocket]()
    
    public internal (set) var udpSockets: [GCDAsyncUdpSocket]! = [GCDAsyncUdpSocket]()
    
    public internal (set) var address: Data?
    
//    public private (set) var controller: Controller! = Controller()
    
    public internal (set) var key: Data?
    
    public internal (set) var IV: Data?
    
    public private (set) var process: DispatchQueue! = DispatchQueue(label: "processQueue")
    
    public private (set) var callback: DispatchQueue! = DispatchQueue(label: "callbackQueue")
    
    public private (set) var serverName: String! = "Swift Play"
    
//    public private (set) var port: UInt16! = 6010
    
    public private (set) var cPort: UInt16! = 6011
    
    public private (set) var tPort: UInt16! = 6012
    
    public var lastSequenceNumber = -1
    
    public var track: Track! = Track()
    
    public var playerState: PlayerState! = PlayerState()
    
    private let serverConfig: ServerConfig! = ServerConfig()
    
    private var socketHandler:SocketHandler?
    
    public func listen(/*on port: UInt16? = nil*/) {
        self.socketHandler = SocketHandler(server: self)
        
        let tcpQueue = DispatchQueue(label: "tcpQueue")
        let socket = GCDAsyncSocket(delegate: self, delegateQueue: tcpQueue)
        
        tcpSockets.append(socket)
        
        do {
            try socket.accept(onPort: port) // TODO: allow more than one connection (index several ports)
        } catch let error {
            print("Error accepting on port: \(error)")
        }
        
        let name = serverConfig.macAddress.reduce("") {
            return $0 + String(format: "%02X", $1)
        } + "@\(self.serverName!)"
        
        print("Server Name: \(name)")
        
        self.service = NetService(
            domain: serverConfig.serviceDomain,
            type: serverConfig.serviceType,
            name: name,
            port: Int32(port))
        guard let service = self.service else {
            print("ERROR creating service")
            return
        }
        
        service.setTXTRecord(NetService.data(fromTXTRecord: serverConfig.txtRecord))
        service.publish()
        print("published")
        
        var audioStream = AudioStreamBasicDescription()
        audioStream.mSampleRate = 44100
        audioStream.mFormatID = kAudioFormatAppleLossless
        audioStream.mFramesPerPacket = 352
        audioStream.mChannelsPerFrame = 2
        
        let status = AudioQueueNewOutputWithDispatchQueue(
            &self.playerState.queue,
            &audioStream,
            0,
            self.callback) { aq, buffer in
                self.output(self.playerState, aq: aq, buffer: buffer)
        }
        assert(status == noErr)
        
        var cookie = serverConfig.cookie
        
        guard let playerStateQueue = self.playerState.queue else {
            print("ERROR playerState queue nil!")
            return
        }
        AudioQueueSetProperty(playerStateQueue, kAudioQueueProperty_MagicCookie, &cookie, 24)
        
        while playerState.buffers.count < serverConfig.bufferCount {
            var buffer: AudioQueueBufferRef? = nil
            
            // "Buffer fits at least one packet of the max possible size"
            AudioQueueAllocateBufferWithPacketDescriptions(
                playerStateQueue,
                serverConfig.bufferSize,
                48,
                &buffer)
            
            guard let bangBuffer = buffer else {
                print("ERROR buffer is nil")
                return
            }
            self.playerState.buffers.append(bangBuffer)
        }
    }
    
    public func output (_ playerState: PlayerState, aq: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let max = Int64(self.playerState.packets.count - 1)
        var packetsCount = 0
        var offset = 0
        var time = UInt32(0)
        
        while self.playerState.packetsRead < playerState.packetsWritten {
            let index = Int(self.playerState.packetsRead & max) // combining matching binary elements
            let packet = self.playerState.packets[index]
            let count = packet.data.count
            
            // Make sure its in the right order
            if  /*packet.index != UInt16(playerState.packetsRead & 65535)*/
                index != self.playerState.packetsRead || packet.index == 0 { // TODO: what is the significance of `65535`
                print("skiping: \(packet.index) with read: \(self.playerState.packetsRead), index: \(index)") // TODO: remove extra logs (like this one)
                
                self.playerState.packetsRead += 1
                continue // skip back to the top of the loop
            } else { print("ok") }
            
            // we ran out of buffer space
            if offset + count > serverConfig.bufferSize { break }
            
            // Make sure the player time is the same as the time being sent
            if self.playerState.queueTime == 0 {
                self.playerState.queueTime = packet.timeStamp
            }
            
            // "Find playback time for first buffered packet"
            if packet.timeStamp >= self.playerState.queueTime && time == 0 {
                time = UInt32(packet.timeStamp - self.playerState.queueTime)
            }
            
            // Set the buffer / packet discriptions
            print("buffer: \(buffer.pointee.mAudioData), offset: \(offset)")
//            let packetData = Utils.fromByteArray(buffer.pointee.mAudioData, UInt8.self)
//            buffer.pointee.mAudioData
//            packetData.withUnsafeMutableBytes {
//                if let ptr = $0.baseAddress {
//                    //  = ptr
//                }
//            }
            _ = packet.data.copyBytes(to: UnsafeMutableBufferPointer(start: buffer, count: packet.data.count))

            packetsCount += 1
            offset += count
            self.playerState.packetsRead += 1
        }
        
        print("setting data size: \(offset)")
        buffer.pointee.mAudioDataByteSize = UInt32(offset * 2024)
        
        buffer.pointee.mPacketDescriptionCount = UInt32(packetsCount)
        
        // add specific playback tiem
        var error = Int32(0)
        var timeStamp = AudioTimeStamp()
        
        timeStamp.mSampleTime = Double(time)
        AudioQueueFlush(aq)
        
        let description = UnsafeRawPointer([
            AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(offset))
            ]).assumingMemoryBound(to: AudioStreamPacketDescription.self)
        
        // caluculate the error
        error = AudioQueueEnqueueBufferWithParameters(aq, buffer, 0, nil, 0, 0, 0, nil, &timeStamp, nil)
        
        // update if necissary because of error
        if error != 0 {
            // retry with this buffer
            self.playerState.buffers.append(buffer)
            self.playerState.queueTime = 0
            
            print("ERROR: Audio Queue Enqueue Error: \(error)")
            // TODO: add debug info
            
            self.process.async {
                self.lastSequenceNumber = -1
            }
                        
            AudioQueuePause(aq)
        }
    }
    
    // MARK - Socket Deligate
    
    public func socket(_ sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        self.tcpSockets.append(newSocket)
        
        guard let separator = "\r\n\r\n".data(using: .utf8) else {
            print("Error encoding seporator data")
            return
        }
        
        newSocket.readData(to: separator, withTimeout: 5, tag: 0)
    }
    
    // Socket Tags:
    //      - 0: RSTP, streaming
    //      - 1: SDP, description
    //      - 2: Artwork Data
    //      - 3: parameters
    //      - 4: DMAP: basically a HTTP server that responds to
    //              specific commands and streams events back to the client.
    //              https://github.com/postlund/pyatv/blob/master/docs/protocol.rst
    
    public func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {        
        switch tag {
        case 0:
            socketHandler?.RTSP(withData: data, forSocket: sock)
        case 1:
            socketHandler?.SDP(withData: data, forSocket: sock)
        case 2:
            self.track.artwrok = data
        case 3:
            socketHandler?.parameters(withData: data)
        case 4:
            socketHandler?.DMAP(withData: data)
        default:
            break
        }
    }
    
    public func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        // audio data port = server port
        if sock.localPort() == port {
            self.process.async {
                self.socketHandler?.process(packet: data)
            }
        }
        
        // control port (cPort)
        if sock.localPort() == self.cPort {
            if self.address != address {
                self.address = address
            }
            
            self.process.async {
                self.socketHandler?.process(packet: data)
            }
        }
    }
    
    public func socket(_ sock: GCDAsyncSocket,
                       shouldTimeoutReadWithTag tag: Int,
                       elapsed: TimeInterval,
                       bytesDone length: UInt) -> TimeInterval {
        // TODO: timed out - probably re-connect
        return 0
    }
}
