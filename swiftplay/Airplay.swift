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
    
    public private (set) var audioSession: AudioSession
    
    public override init() {
        self.audioSession = AudioSession(withState: self.playerState)
    }
    
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
        
        self.audioSession.start()
        
//        while playerState.buffers.count < serverConfig.bufferCount {
//            var buffer: AudioQueueBufferRef? = nil
//
//            // "Buffer fits at least one packet of the max possible size"
//            AudioQueueAllocateBufferWithPacketDescriptions(
//                playerStateQueue,
//                serverConfig.bufferSize,
//                48,
//                &buffer)
//
//            guard let bangBuffer = buffer else {
//                print("ERROR buffer is nil")
//                return
//            }
//            self.playerState.buffers.append(bangBuffer)
//        }
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
