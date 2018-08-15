//
//  SocketHandler.swift
//  swiftplay
//
//  Created by Zoe IAMZOE.io on 8/14/18.
//  Copyright © 2018 Zoe IAMZOE.io. All rights reserved.
//

import Foundation
import AudioToolbox
import CocoaAsyncSocket
import Security
import CommonCrypto

let verbose: Bool = false

public class SocketHandler {
    
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
            
            if let TRPInfo = headers["RTP-Info"] {
                getCurrentSequenceNumber(withRTPInfo: TRPInfo)
            }
        }
        
        if verbose {
            print("--- Headers: \(headers) ---")
            print("Req Type: \(requestType)")
        }
        
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
            let data = data as NSData
            
            if verbose {
                print("offset: \(offset)")
            }
            
            let tagBytes = data.subdata(with: NSMakeRange(offset, 4))
            let tag = String(data: tagBytes, encoding: .utf8) ?? String()
            
            offset += 4 // tag is 4 bytes
            
            if tag == "mlit" { // TODO: enumify (make it an enum)
                offset += 4
                continue
            }
            
            let size = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            
            let sizeBytes = data.subdata(with: NSMakeRange(offset, 4))
            sizeBytes.copyBytes(to: size, count:4)
            size.pointee = size.pointee.byteSwapped
            
            offset += 4
            
            if offset >= data.length { return }
            else if offset + Int(size.pointee) > data.length {
                size.pointee = UInt8(data.length - offset)
            }
            let value = data.subdata(with: NSMakeRange(offset, Int(size.pointee)))
            let stringValue = String(data: value, encoding: .utf8)
            let intValue = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            
            value.copyBytes(to: intValue, count: value.count)
            
            // switch on DAAP format
            switch tag { // TODO: this should be an enum
            case "asal":
                server.track.album = stringValue ?? "Error reading album"
            case "asar":
                server.track.artist = stringValue ?? "Error getting artist"
            case "minm":
                server.track.name = stringValue ?? "Error Reading Name" // maybe handle this better?
            case "caps":
                server.track.playing = intValue.pointee == 1
            default:
                break
            }
            
            offset += Int(size.pointee)
        }
    }
    
    // MARK - Process Data
    
    open func process(packet data: Data) {
        let data = data as NSData
        
        let type = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024) // <UInt8>.allocate(capacity: 1024)
        let timeStamp = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024) // Should be 32
        let sequenceNumber = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024) // Should be 16
        var payload = NSData()
        
        data.subdata(with: NSMakeRange(1, 1)).copyBytes(to: type, count: 1)
        print("type: \(type.pointee)")
        
        // New audio packet
        if type.pointee == 96 || type.pointee == 224 {
            data.subdata(with: NSMakeRange(4, 4)).copyBytes(to: timeStamp, count: 4)
            data.subdata(with: NSMakeRange(2, 2)).copyBytes(to: sequenceNumber, count: 2)
            payload = data.subdata(with: NSMakeRange(12, data.length - 12)) as NSData
            print("Sequence Number: \(sequenceNumber.pointee)")
            
            timeStamp.pointee = timeStamp.pointee.byteSwapped
            sequenceNumber.pointee = sequenceNumber.pointee.byteSwapped
            
            // Request any missing packets
            if  server.lastSequenceNumber != -1
                && Int(sequenceNumber.pointee &- 1) != server.lastSequenceNumber {
                print("requesting new packets")
                
                // Retransmit request header
                var header: [UInt8] = [128, 213, 0, 1]
                let request = NSMutableData(bytes: &header, length: 4)
                let numberOfPackets = sequenceNumber.pointee &- UInt8(server.lastSequenceNumber) &- 1
                var sequenceNumberBytes = (UInt16(server.lastSequenceNumber) &+ 1).byteSwapped
                var numberOfPacketsBytes = numberOfPackets.byteSwapped
                
                request.append(&sequenceNumberBytes, length: 2)
                request.append(&numberOfPacketsBytes, length: 2)
                
                // Limit resend attempts
                if server.address!.count > 0 && numberOfPackets < 128 {
                    let controlPort = server.udpSockets[1]
                    controlPort.send(request as Data, toAddress: server.address!, withTimeout: 5, tag: 0)
                }
                
                #if DEBUG
                print("Retransmit: \(sequenceNumberBytes.byteSwapped)",
                    "Packets: \(numberOfPackets)",
                    "Current: \(Int(sequenceNumber.pointee &- 1))",
                    "Last: \(server.lastSequenceNumber)"
                )
                #endif
            }
            
            server.lastSequenceNumber = Int(sequenceNumber.pointee)
        }
            // Retransmitted packet
        else if type.pointee == 214 {
            // Ignore malformed packets
            if data.length < 16 {
                return
            }
            
            data.subdata(with: NSMakeRange(8, 4)).copyBytes(to: timeStamp, count: 4)
            data.subdata(with: NSMakeRange(6, 2)).copyBytes(to: sequenceNumber, count: 2)
            payload = data.subdata(with: NSMakeRange(16, data.length - 16)) as NSData
            
            timeStamp.pointee = timeStamp.pointee.byteSwapped
            sequenceNumber.pointee = sequenceNumber.pointee.byteSwapped
        }
            // Ignore unknown packets
        else {
            return
        }
        
        var packet = Packet()
        packet.data = payload as Data
        packet.timeStamp = UInt32(timeStamp.pointee)
        packet.index = UInt16(sequenceNumber.pointee)
        
        // TODO: handle end
        
        guard let decryptedPacket = self.decrypt(packet: packet) else {
            print("ERROR: decrypted nil packet")
            return
        }
        
        server.callback.async {
            self.prepareAudioQueue(forPacket: decryptedPacket)
        }
    }
    
    // Dissabled
    /*open func process(packet data: Data) {
        if verbose {
            let fullData = data.map {
                return String(UInt8($0)) + ", " +
                    String(UInt16($0))  + ", " +
                    String(UInt32($0))
                }.joined(separator: "-")
            
            print("Full data \n -- \(fullData) -- \n")
        }
        
        var data = data
        var type = UInt8(0)
        var timeStamp = UInt32(0)
        var sequenceNumber = UInt16(0)
        var payload = Data()
        
        type = data.bytesForRange(1, 1, count: 1)
        
        // new audio packet
        if type == 96 || type == 224 {
            timeStamp = data.bytesForRange(4, 4, count: 4)
            sequenceNumber = data.bytesForRange(4, 4, count: 2)
            payload = data.subdata(in: Utils.makeRange(12, data.count - 12))
            
            timeStamp = timeStamp.byteSwapped
            sequenceNumber = sequenceNumber.byteSwapped
            
            guard let address = server.address else {
                print("ERROR nil address")
                return
            }
            
            // missing packets
            if  server.lastSequenceNumber != -1
                && Int(sequenceNumber) != server.lastSequenceNumber {

                // resent request header
                var header: [UInt8] = [128, 213, 0, 1]
                let request = NSMutableData(bytes: &header, length: 4)
                let numberOfPackets = sequenceNumber &- UInt16(server.lastSequenceNumber) &- 1
                var sequenceNumberBytes = (UInt16(server.lastSequenceNumber) &+ 1).byteSwapped
                var numberOfPacketsBytes = numberOfPackets.byteSwapped
                
                request.append(&sequenceNumberBytes, length: 2)
                request.append(&numberOfPacketsBytes, length: 2)
                
                // Limit resend attempts
                if address.count > 0 && numberOfPackets < 128 {
                    let controlPort = server.udpSockets[1]
                    controlPort.send(request as Data, toAddress: address, withTimeout: 5, tag: 0)
                }

                if verbose {
                    print("""
                        Retransmit: \(sequenceNumberBytes.byteSwapped)
                        Packets: \(numberOfPackets)
                        Current: \(Int(sequenceNumber &- 1))
                        Last: \(server.lastSequenceNumber)
                    """)
                }
            }
            
            server.lastSequenceNumber = Int(sequenceNumber)
        } else if type == 214 { // retransmitted packets
            print("Recived Re-transmitted Package")
            
            // ignore malformed packets
            if data.count < 16 {
                return
            }
            
            timeStamp = data.bytesForRange(8, 8, count: 4)
            sequenceNumber = data.bytesForRange(6, 2, count: 2)
            payload = data.subdata(in: Utils.makeRange(4, data.count - 16))
            
            timeStamp = timeStamp.byteSwapped
            sequenceNumber = sequenceNumber.byteSwapped
        } else { return }  // unknown packets
        
        var packet = Packet()
        packet.data = payload
        packet.timeStamp = timeStamp
        packet.index = sequenceNumber &+ 1
        
        guard let decryptedPacket = self.decrypt(packet: packet) else {
            print("ERROR: decrypted nil packet")
            return
        }
        
        server.callback.async {
            self.prepareAudioQueue(forPacket: decryptedPacket)
        }
    }*/
    
    // MARK - private
    
    private func getCurrentSequenceNumber(withRTPInfo RTPInfo: String) {
        let field = RTPInfo.components(separatedBy: "=;")
        var sequenceNumber = -1
        
        for i in 0 ..< field.count {
            if field[i] == "seq" {
                sequenceNumber = Int(field[i + 1]) ?? -1
            }
        }
        
        if sequenceNumber != -1 {
            server.callback.async {
                self.server.playerState.packetsRead = Int64(sequenceNumber)
                self.server.playerState.packetsWritten = Int64(sequenceNumber)
                self.server.playerState.sessionTime = 0
                
            }
        }
    }
    
    // TODO: Dont use this
    static private func respondToChallenge(challenge: String, fromSocket sock: GCDAsyncSocket!) -> String {
        let responseData = NSMutableData()
        let encodedData = NSData(base64Encoded: challenge, options: .init(rawValue: 0))

        responseData.append(encodedData! as Data)
        
        // Append IP and MAC address to response
        let address = sock.localAddress! as NSData
        let length = address.length
        let range = sock.isIPv6 ? NSMakeRange(length - 20, 16) : NSMakeRange(length - 12, 4)
        print(address.subdata(with: range))
        responseData.append(address.subdata(with: range))
        responseData.append(ServerConfig().macAddress, length: 6)
        
        if responseData.length < 32 {
            responseData.increaseLength(by: 32 - responseData.length)
        }
        
        // Sign with private key
        let signedResponse = RSATransform(withType: .sign, andInput: responseData as Data) as NSData
        
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
                print("ERROR: player queue (aq) is nil!")
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
