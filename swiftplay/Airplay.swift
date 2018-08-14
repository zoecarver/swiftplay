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

public struct PlayerState { // wish that this could just be static!
    var queue: AudioQueueRef?
    var buffers: [AudioQueueBufferRef]! = [AudioQueueBufferRef]()
    var packets = [Packet](repeating: Packet(), count: 1024)
    var packetsRead = Int64(0)
    var packetsWritten = Int64(0)
    var queueTime = UInt32(0)
    var sessionTime = UInt32(0)
}

public struct Packet {
    var data = Data()
    var index = UInt8(0)
    var timeStamp = UInt32(0)
}

private struct ServerConfig {
    
    private var UID: UInt8! = 1
    
    // TOOD: these should all be public static lets
    let txtFields = ["et": "1", "sf": "0x4", "tp": "UDP", "vn": "3", "cn": "1", "md": "0,1,2"]
    let txtRecord: [String: Data]!
    
    let macAddress: [UInt8] = [
        10,
        10,
        10,
        10,
        10,
        /*UID TODO:*/ 1
    ]
    
    let serviceType: String! = "_raop._tcp."
    let serviceDomain: String! = ""
    
    let cookie: [UInt8] = [0, 0, 1, 96, 0, 16, 40, 10, 14, 2, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 172, 68]
    
    let bufferCount: Int! = 3
    
    let bufferSize: UInt32! = 1536
    
    init() {
        //TODO: when this is static put it inline
        self.txtRecord = Dictionary(uniqueKeysWithValues: txtFields.map { arg in
            let (key, val) = arg
            return (key, val.data(using: .utf8)!) // ususally wouldnt force cast but here its okay
        })
    }
}

protocol Server {
    var service: NetService? { get set }
    var tcpSockets: [GCDAsyncSocket]! { get set }
    var udpSockets: [GCDAsyncUdpSocket]! { get set }
    var address: Data? { get set }
    
//    var controller: Controller! { get }
    var key: Data? { get set }
    var IV: Data? { get set }
    
    var process: DispatchQueue! { get }
    var callback: DispatchQueue! { get }
    
    var serverName: String! { get }
    
//    var port: UInt16! { get }
    var cPort: UInt16! { get }
    var tPort: UInt16! { get }
    
    var track: Track! { get set }
    
    func listen()
}

public class AirplayServer: NSObject, Server, GCDAsyncSocketDelegate, GCDAsyncUdpSocketDelegate {
    
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
        
        AudioQueueNewOutputWithDispatchQueue(
            &self.playerState.queue,
            &audioStream,
            0,
            self.callback) { aq, buffer in
                self.output(self.playerState, aq: aq, buffer: buffer)
        }
        
        var cookie = serverConfig.cookie
        
        guard let playerStateQueue = self.playerState.queue else {
            print("ERROR playerState queue nil!")
            return
        }
        AudioQueueSetProperty(playerStateQueue, kAudioQueueProperty_MagicCookie, &cookie, 24)
        
        while playerState.buffers.count < serverConfig.bufferCount {
            var buffer: AudioQueueBufferRef?
            
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
            if packet.index != UInt16(playerState.packetsRead & 65535) { // TODO: what is the significance of `65535`
                print("skiping: \(packet.index) with index: \(self.playerState.packetsRead & 65535)") // TODO: remove extra logs (like this one)
                
                self.playerState.packetsRead += 1
                continue // skip back to the top of the loop
            }
            
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
            if var description = buffer[0].mPacketDescriptions?[packetsCount] {
                description.mStartOffset = Int64(offset)
                description.mDataByteSize = UInt32(count)
                description.mVariableFramesInPacket = 0
            }

            packetsCount += 1
            offset += count
            self.playerState.packetsRead += 1
        }
        
        buffer[0].mAudioDataByteSize = UInt32(offset)
        buffer[0].mPacketDescriptionCount = UInt32(packetsCount)
        
        // add specific playback tiem
        var error = Int32(0)
        var timeStamp = AudioTimeStamp()
        
        timeStamp.mSampleTime = Double(time)
        AudioQueueFlush(aq)
        // caluculate the error
        error = AudioQueueEnqueueBufferWithParameters(aq, buffer, 0, nil, 0, 0, 0, nil, &timeStamp, nil)
        
        // update if necissary
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
        print("TAG: \(tag)")
        
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

private class SocketHandler {
    
    /*weak*/ var server: AirplayServer!
    
    init(server: AirplayServer) {
        self.server = server
    }
    
    private enum RequestTypes: String {
        case options = "OPTIONS"
        case setup = "SETUP"
        case record = "RECORD"
        case flush = "FLUSH"
        case teardown = "TEARDOWN"
    }
    
    open func RTSP (withData data: Data, forSocket socket: GCDAsyncSocket) {
        guard let request = String(data: data, encoding: .utf8) else {
            print("Error decoding RTSP data")
            return
        }
        
        var headers = [String: String]()
        var requestType = String()
        var response = ["RTSP/1.0 200 OK"]
        
        // get headers
        for req in request.components(separatedBy: "\r\n") {
            let feild = req.components(separatedBy: ": ")
            
            // request type
            if feild.count == 1 && requestType == "" {
                for char in Array(feild[0]) {
                    if char == " " {
                        break // exit if empty (the type has been set)
                    }
                    
                    // otherwise add to the request type
                    requestType.append(char)
                }
            // other headers
            } else if feild.count == 2 {
                headers[feild[0]] = feild[1]
            }
        }
        
        // MARK - helper function
        func isAppleChallenge () {
            if let appleChallenge = headers["Apple-Challenge"] {
                let paddedChallenge = Utils.padBase64(string: appleChallenge)
                let appleResponse = SocketHandler.respondToChallenge(challenge: paddedChallenge, fromSocket: socket) // SocketHandler.respond(toChallenge: paddedChallenge, forSocket: socket)
                
                response += ["Apple-Response: \(appleResponse)"]
            }
        }
        
        func isSetup () {
            // port is explicitly declared optional but who knows swift! thanks for wasting my morning :)
            response += ["Transport: RTP/AVP/UDP;server_port=\(port!);control_port=\(server.cPort!)"]
            response += ["Session: 1"]
            
            self.createSessionSockets()
            server.track.playing = true
            
            print("Setup Response: \(response)")
        }
        
        func isFlush () {
            guard let playerStateQueue = server.playerState.queue else {
                print("Error no player state queue")
                return
            }
            
            server.process.async {
                self.server.lastSequenceNumber = -1
            }
            
            AudioQueueReset(playerStateQueue) // TODO hoping that this is passed by refrence but it might not be
            
            server.callback.async {
                self.server.playerState.queueTime = 0
            }
        }
        
        print("--- Headers: \(headers) ---")
        print("Req Type: \(requestType)")
        
        // MARK - session control flow
        switch RequestTypes(rawValue: requestType) {
        case .options?:
            isAppleChallenge()
        case .setup?:
            isSetup()
        case .record?:
            fallthrough
        case .flush?:
            isFlush()
        case .teardown?:
            server.track = Track() // reset track
        default:
            break
        }
        
        // audio metadata
        if let contentType = headers["Content-Type"] {
            // defaults to 0 if unwrapping is unsuccesful
            let contentCount = UInt(headers["Content-Length"] ?? "0") ?? 0
            
            switch contentType {
            case "application/sdp":
                socket.readData(toLength: contentCount, withTimeout: 5, tag: 1)
            case "image/jpeg":
                socket.readData(toLength: contentCount, withTimeout: 5, tag: 2)
            case "text/parameters":
                socket.readData(toLength: contentCount, withTimeout: 5, tag: 3)
            case "application/x-dmap-tagged":
                socket.readData(toLength: contentCount, withTimeout: 5, tag: 4)
            default:
                break
            }
        }
        
        let sequence = headers["CSeq"] ?? "0"
        response += ["CSeq: \(sequence)"]
        response += ["\r\n"]
        
        // TODO: print some info here
        
        let joinedReponses = response.joined(separator: "\r\n")
        if  let responseData = joinedReponses.data(using: .utf8),
            let seporator = "\r\n\r\n".data(using: .utf8) { // TODO: we use this data alot might be good to store it somewhere
            // TODO: store timeout (5) in server config
            socket.write(responseData, withTimeout: 5, tag: 0)
            socket.readData(to: seporator, withTimeout: 5, tag: 0)
        }
    }
    
    open func SDP (withData data: Data, forSocket socket: GCDAsyncSocket) {
        let session = String(data: data, encoding: .utf8) ?? String()
//        print(" --- SDP: \(session) --- ")
        let sessionData:[String] = session.components(separatedBy: "\r\n")
        var attributes: [String: String] = [:]
        
        for ses in sessionData { // ses will be in the form of `a=rtpmap:96 AppleLossless`
            if Array(ses).first == "a" { // if it starts with `a` we want the data from it
                let index2 = ses.index(ses.startIndex, offsetBy: 2)
                let attribute = ses[ index2... ] // remove the first two chars `a=`
                let components = attribute.components(separatedBy: ":")
                
                attributes[components[0]] = components[1]
            }
        }
        
        // descrypt AES session key using the RSA key
        let options = NSData.Base64DecodingOptions(rawValue: 0)
        
        if let key = attributes["rsaaeskey"] {
            let paddedKey = Utils.padBase64(string: key)
            
            if let keyData = Data(base64Encoded: paddedKey, options: options) {
                self.server.key = RSATransform(withType: .decript, andInput: keyData)
            }
        }
        
        if let IV = attributes["aesiv"] {
            let paddedIV = Utils.padBase64(string: IV)
            
            if let IVData = Data(base64Encoded: paddedIV, options: options) {
                self.server.IV = IVData
            }
        }
    }
    
    open func parameters(withData data: Data) {
        guard let parameters = String(data: data, encoding: .utf8) else {
            print("ERROR: could not decode prameters")
            return
        }
        
        let separators = CharacterSet(charactersIn: "/: \r\n") // TODO: move this into a config
        let field = parameters.components(separatedBy: separators)
        
        if field[0] == "progress" {
            // Position and duration are set to -1 using default values
            let startTime = Double(field[2]) ?? 1
            let currentTime = Double(field[3]) ?? 0
            let endTime = Double(field[4]) ?? 0
            
            // AirTunes uses a fixed 44.1kHz sampling rate
            server.track.position = round((currentTime - startTime) / 44100) // TODO: put the 44.1 into a config
            server.track.duration = round((endTime - startTime) / 44100)
        }
    }
    
    open func DMAP(withData data: Data) {
        var offset = 0
        
        while offset < data.count {
            guard let tagRange = Range(NSMakeRange(offset, 4)) else { // TODO: use good range
                print("Error: invalid range for tag")
                return
            }
            
            let tagBytes = data.subdata(in: tagRange)
            
            guard let tag = String(data: tagBytes, encoding: .utf8) else {
                print("Error: Could not decode tag bytes")
                return
            }
            
            offset += 4 // tag is 4 bytes
            
            if tag == "mlit" { // TODO: enumify (make it an enum)
                offset += 4
                continue
            }
            
            var size: UInt8 = 0
            
            guard let sizeRange = Range(NSMakeRange(offset, 4)) else { // TODO: use good range
                print("Error: invalid range for size")
                return
            }
            
            let sizeBytes = data.subdata(in: sizeRange)
            
            sizeBytes.copyBytes(to: &size, count: 4)
            size = size.byteSwapped
            offset += 4
            
            guard let valueRange = Range(NSMakeRange(offset, 4)) else { // TODO: use good range
                print("Error: invalid range for value")
                return
            }
            
            let value = data.subdata(in: valueRange)
            let valueS = String(data: value, encoding: .utf8)
            var valueI: UInt8 = 0
            
            value.copyBytes(to: &valueI, count: value.count)
            
            // switch on DAAP format
            switch tag { // TODO: this should be an enum
            case "asal":
                server.track.album = valueS ?? "Error reading album"
            case "asar":
                server.track.artist = valueS ?? "Error getting artist"
            case "minm":
                server.track.name = valueS ?? "Error Reading Name" // maybe handle this better?
            case "caps":
                server.track.playing = valueI == 1
            default:
                break
            }
            
            offset += Int(size)
        }
    }
    
    open func process(packet data: Data) {
        var type = UInt8(0)
        var timeStamp = UInt8(0)
        var sequenceNumber = UInt8(0)
        var payload = Data()
        
        guard let typeRange = Range(NSMakeRange(1, 1)) else {
            print("Error creating range for packet type")
            return
        }
        
        data.subdata(in: typeRange).copyBytes(to: &type, count: 1)
        
        // new audio packet
        if type == 96 || type == 224 {
            data.subdata(in: Utils.makeRange(4, 4)).copyBytes(to: &timeStamp, count: 4)
            data.subdata(in: Utils.makeRange(4, 4)).copyBytes(to: &sequenceNumber, count: 2)
            payload = data.subdata(in: Utils.makeRange(4, data.count - 12))
            
            timeStamp = timeStamp.byteSwapped
            sequenceNumber = sequenceNumber.byteSwapped
            
            guard let address = server.address else {
                print("ERROR nil address")
                return
            }
            
            if server.lastSequenceNumber != -1
                && Int(sequenceNumber &- 1) != server.lastSequenceNumber {
                
                // resent request header
                var header: [UInt8] = [128, 213, 0, 1]
                let request = NSMutableData(bytes: &header, length: 4)
                let numberOfPackets = sequenceNumber &- UInt8(server.lastSequenceNumber) &- 1
                var sequenceNumberBytes = (UInt16(server.lastSequenceNumber) &+ 1).byteSwapped
                var numberOfPacketsBytes = numberOfPackets.byteSwapped
                
                request.append(&sequenceNumberBytes, length: 2)
                request.append(&numberOfPacketsBytes, length: 2)
                
                // Limit resend attempts
                if address.count > 0 && numberOfPackets < 128 {
                    let controlPort = server.udpSockets[1]
                    controlPort.send(request as Data, toAddress: address, withTimeout: 5, tag: 0)
                }
                
                print("""
                    Retransmit: \(sequenceNumberBytes.byteSwapped)
                    Packets: \(numberOfPackets)
                    Current: \(Int(sequenceNumber &- 1))
                    Last: \(server.lastSequenceNumber)
                """)
            }
            
            server.lastSequenceNumber = Int(sequenceNumber)
        } else if type == 214 { // retransmitted packets
            // ignore malformed packets
            if data.count < 16 {
                return
            }
            
            data.subdata(in: Utils.makeRange(8, 8)).copyBytes(to: &timeStamp, count: 4)
            data.subdata(in: Utils.makeRange(6, 2)).copyBytes(to: &sequenceNumber, count: 2)
            payload = data.subdata(in: Utils.makeRange(4, data.count - 16))
            
            timeStamp = timeStamp.byteSwapped
            sequenceNumber = sequenceNumber.byteSwapped
        } else { // unknown packets
            return
        }
        
        var packet = Packet()
        packet.data = payload
        packet.timeStamp = UInt32(timeStamp)
        packet.index = sequenceNumber
        
        server.callback.async {
            guard let packet = self.decrypt(packet: packet) else {
                print("ERROR: decrypted nil packet")
                return
            }
            
            self.prepareAudioQueue(forPacket: packet)
        }
    }
    
    // MARK - private
    
    // TODO: Dont use this
    static private func respondToChallenge(challenge: String, fromSocket sock: GCDAsyncSocket!) -> String {
        let responseData = NSMutableData()
        let encodedData = NSData(base64Encoded: challenge, options: .init(rawValue: 0))
        print("1")
        responseData.append(encodedData! as Data)
        
        // Append IP and MAC address to response
        print("2")
        let address = sock.localAddress! as NSData
        print("3")
        let length = address.length
        let range = sock.isIPv6 ? NSMakeRange(length - 20, 16) : NSMakeRange(length - 12, 4)
        print(address.subdata(with: range))
        responseData.append(address.subdata(with: range))
        responseData.append(ServerConfig().macAddress, length: 6)
        
        if responseData.length < 32 {
            responseData.increaseLength(by: 32 - responseData.length)
        }
        
        // Disconnect any other sessions
        /*for i in 1..<tcpSockets.count {
         if tcpSockets[i].localPort == 5001 && tcpSockets[i] == sock {
         break
         }
         
         tcpSockets[i].disconnect()
         }*/
        
        // Sign with private key
        let signedResponse = RSATransform(withType: .sign, andInput: responseData as Data) as NSData
        
        print("4")
        return signedResponse.base64EncodedString(options: .init(rawValue: 0))
    }
    
    static private func respond(toChallenge challenge: String, forSocket socket: GCDAsyncSocket) -> String {
        let serverConfig = ServerConfig() // TODO: remove when static 😡
        
        var responseData = Data()
        guard let encodedData = Data(base64Encoded: challenge, options: .init(rawValue: 0)) else { // because string.encode would be too hard ¯\_(ツ)_/¯
            print("ERROR: encoding data")
            return ""
        }
        
        responseData.append(encodedData)
        
        // add ip and mac address to response
        guard var ipAddress = socket.localAddress else {
            print("ERROR: no ip address!")
            return ""
        }
        
        let count = ipAddress.count
        let range: Range = socket.isIPv6 ?
            (count - 20 ..< 16) : (count - 12 ..< 4)
        ipAddress = ipAddress.subdata(in: range)
        
        print("ip address: \(ipAddress)")
        responseData.append(ipAddress)
        responseData.append(serverConfig.macAddress, count: 6)
        
        if responseData.count < 32 {
            responseData.append(
                UnsafeMutablePointer<UInt8>.allocate(capacity: 0 /*TODO: make this 1?*/),
                count: 32 - responseData.count)
        }
        
        // sign with key
        let signedResponse = RSATransform(withType: .sign, andInput: responseData)
        return signedResponse.base64EncodedString(options: .init(rawValue: 0))
    }
    
    private func createSessionSockets () {
        if server.udpSockets.count > 0 {
            return
        }
        
        let udpQueue = DispatchQueue(label: "udpQueue") //TODO: enum for queues
        let serverPort = GCDAsyncUdpSocket(delegate: server, delegateQueue: udpQueue)
        let controlPort = GCDAsyncUdpSocket(delegate: server, delegateQueue: udpQueue)
        let timingPort = GCDAsyncUdpSocket(delegate: server, delegateQueue: udpQueue)
        
        do {
            try serverPort.bind(toPort: port)
            try controlPort.bind(toPort: server.cPort)
            try timingPort.bind(toPort: server.tPort)
        } catch let error {
            print("Error binding port: \(error)")
        }
        
        do {
            try serverPort.beginReceiving()
            try controlPort.beginReceiving()
            try timingPort.beginReceiving()
        } catch let error {
            print("Error reciving: \(error)")
        }
        
        server.udpSockets = [ serverPort, controlPort, timingPort ]
    }
    
    private func decrypt(packet: Packet) -> Packet? {
        var packet = packet // make mutable
        
        var cryptor: CCCryptorRef?
        let count = packet.data.count
        var output = [UInt8](repeating: 0, count: count)
        var moved = 0
        
        guard   let key = server.key,
                let IV = server.IV else {
            print("Error no key")
            return nil
        }
        
        // Unforuntunatelly we have to use nsdata here because swift 4 thinks we cant touch bytes
        CCCryptorCreate(
            UInt32(kCCDecrypt),
            0,
            0,
            (key as NSData).bytes,
            16,
            (IV as NSData).bytes,
            &cryptor)
        CCCryptorUpdate(
            cryptor,
            (packet.data as NSData).bytes,
            count,
            &output,
            output.count,
            &moved)
        
        // Remaining data is plain-text
        // again we unforuntately have to use NS
        let decrypted = NSMutableData(bytes: &output, length: moved)
        let remaining = Utils.makeRange(decrypted.length, count - decrypted.length) // Range = decrypted.length ..< count - decrypted.length
        decrypted.append(packet.data.subdata(in: remaining))
        CCCryptorRelease(cryptor)
        packet.data = decrypted as Data
        
        return packet
    }
    
    private func prepareAudioQueue(forPacket packet: Packet) {
        let maxIndex = server.playerState.packets.count - 1
        let index = Int(packet.index) & maxIndex
        let remainingBuffer = server.playerState.packetsWritten - server.playerState.packetsRead
        
        server.playerState.packets[index] = packet
        
        // one frame before the initial time
        if server.playerState.sessionTime == 0 && packet.timeStamp >= 352 { // Prevent overflow on unsinged type
            server.playerState.sessionTime = packet.timeStamp - 352
        }
        
        // wrap-around condition
        let upperBound = UInt32(255 << 12)
        let lowerBound = UInt32(255 << 24)
        let wrapsAround = packet.timeStamp < upperBound
            && server.playerState.sessionTime > lowerBound
        
        // get number of new packets
        if packet.timeStamp > server.playerState.sessionTime || wrapsAround {
            let packetsToAdd = Int64((packet.timeStamp &- server.playerState.sessionTime) / 352)
            server.playerState.packetsWritten += packetsToAdd
            server.playerState.sessionTime = packet.timeStamp
        }
        
        // buffer at least 128 packets before playback
        if remainingBuffer >= 128 {
            server.playerState.packetsRead = server.playerState.packetsWritten - 128
            server.playerState.queueTime = 0
            
            guard let aq = server.playerState.queue else {
                print("ERROr: player queue (aq) is nil!")
                return
            }
            
            for _ in 0 ..< server.playerState.buffers.count {
                let buffer = server.playerState.buffers[0]
                    
                server.output(server.playerState, aq: aq, buffer: buffer)
                server.playerState.buffers.removeFirst()
            }
            
            if server.track.playing {
                AudioQueueStart(aq, nil)
            }
        }
    }
}

private class Utils {
    public static func padBase64(string input: String) -> String {
        var paddedInput = input
        
        while paddedInput.count % 4 != 0 {
            paddedInput += "="
        }
        
        return paddedInput
    }
    
    public static func makeRange(_ a: Int, _ b: Int) -> Range<Int> {
        guard let range = Range(NSMakeRange(a, b)) else { // TODO: use good range
            print("Error [make range] : invalid range for value")
            return Range(NSMakeRange(1, 1))!
        }
        
        return range
    }
}
