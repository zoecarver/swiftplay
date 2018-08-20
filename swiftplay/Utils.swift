//
//  Utils.swift
//  swiftplay
//
//  Created by Zoe IAMZOE.io on 8/14/18.
//  Copyright © 2018 Zoe IAMZOE.io. All rights reserved.
//

import Foundation
import AVFoundation

public class Utils {
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
    
    public static func fromByteArray<T>(_ value: [UInt8], _: T.Type) -> T {
        return value.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: T.self, capacity: 1) {
                $0.pointee
            }
        }
    }
}

extension Data {
    func bytesForRange <T: Numeric> (_ a: Int, _ b: Int, count: Int) -> T {
        let bytes = self.subdata(in: Utils.makeRange(a, b)).withUnsafeBytes { byte in
            [T](UnsafeBufferPointer(start: byte, count: count))
        }
        return UnsafePointer<T>(bytes).pointee
    }
    
    func bytes <T: Numeric> (withCount count: Int) -> T {
        let bytes = self.withUnsafeBytes { byte in
            [T](UnsafeBufferPointer(start: byte, count: count))
        }
        return UnsafePointer<T>(bytes).pointee
    }
    
    func toPCMBuffer(withFormat audioFormat: AVAudioFormat) -> AVAudioPCMBuffer {
        let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: UInt32(self.count)/2)!
        audioBuffer.frameLength = audioBuffer.frameCapacity
        for i in 0..<self.count/2 {
            // transform two bytes into a float (-1.0 - 1.0), required by the audio buffer
            audioBuffer.floatChannelData?.pointee[i] = Float(Int16(self[i*2+1]) << 8 | Int16(self[i*2]))/Float(INT16_MAX)
        }
        
        return audioBuffer
    }
    
    func toAVBuffer(withFormat audioFormat: AVAudioFormat) -> AVAudioCompressedBuffer {
        let audioBuffer = AVAudioCompressedBuffer(format: audioFormat, packetCapacity: UInt32(self.count), maximumPacketSize: self.count)
        
        for data in ([UInt8](self).map { Int32($0) }) {
            memset(
                audioBuffer.mutableAudioBufferList[0].mBuffers.mData,
                data,
                MemoryLayout<UInt32>.size)
        }
        
        return audioBuffer
    }
}

class AudioBufferFormatHelper {
    
    static func PCMFormat() -> AVAudioFormat? {
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)
    }
    
    static func AACFormat() -> AVAudioFormat? {
        
        var outDesc = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 352,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0)
        let outFormat = AVAudioFormat(streamDescription: &outDesc)
        return outFormat
    }
}

class AudioBufferConverter {
    static var lpcmToAACConverter: AVAudioConverter! = nil
    
    static func convertToAAC(from buffer: AVAudioBuffer, error outError: NSErrorPointer) -> AVAudioCompressedBuffer? {
        
        let outputFormat = AudioBufferFormatHelper.AACFormat()
        let outBuffer = AVAudioCompressedBuffer(format: outputFormat!, packetCapacity: 8, maximumPacketSize: 768)
        
        //init converter once
        if lpcmToAACConverter == nil {
            let inputFormat = buffer.format
            
            lpcmToAACConverter = AVAudioConverter(from: inputFormat, to: outputFormat!)
            //            print("available rates \(lpcmToAACConverter.applicableEncodeBitRates)")
            //          lpcmToAACConverter!.bitRate = 96000
            lpcmToAACConverter.bitRate = 44100    // have end of stream problems with this, not sure why
        }
        
        self.convert(withConverter:lpcmToAACConverter, from: buffer, to: outBuffer, error: outError)
        
        return outBuffer
    }
    
    static var aacToLPCMConverter: AVAudioConverter! = nil
    
    static func convertToPCM(from buffer: AVAudioBuffer, error outError: NSErrorPointer) -> AVAudioPCMBuffer? {
        
        let outputFormat = AudioBufferFormatHelper.PCMFormat()
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat!, frameCapacity: 4410) else {
            return nil
        }
        
        //init converter once
        if aacToLPCMConverter == nil {
            let inputFormat = buffer.format
            
            aacToLPCMConverter = AVAudioConverter(from: inputFormat, to: outputFormat!)
        }
        
        self.convert(withConverter: aacToLPCMConverter, from: buffer, to: outBuffer, error: outError)
        
        return outBuffer
    }
    
    static func convertToAAC(from data: Data, packetDescriptions: [AudioStreamPacketDescription]) -> AVAudioCompressedBuffer? {
        
        let nsData = NSData(data: data)
        let inputFormat = AudioBufferFormatHelper.AACFormat()
        let maximumPacketSize = packetDescriptions.map { $0.mDataByteSize }.max()!
        let buffer = AVAudioCompressedBuffer(format: inputFormat!, packetCapacity: AVAudioPacketCount(packetDescriptions.count), maximumPacketSize: Int(maximumPacketSize))
        buffer.byteLength = UInt32(data.count)
        buffer.packetCount = AVAudioPacketCount(packetDescriptions.count)
        
        buffer.data.copyMemory(from: nsData.bytes, byteCount: nsData.length)
        buffer.packetDescriptions!.pointee.mDataByteSize = UInt32(data.count)
        buffer.packetDescriptions!.initialize(from: packetDescriptions, count: packetDescriptions.count)
        
        return buffer
    }
    
    
    public static func convert(withConverter: AVAudioConverter, from sourceBuffer: AVAudioBuffer, to destinationBuffer: AVAudioBuffer, error outError: NSErrorPointer) {
        // input each buffer only once
        var newBufferAvailable = true
        
        let inputBlock : AVAudioConverterInputBlock = {
            inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        
        let status = withConverter.convert(to: destinationBuffer, error: outError, withInputFrom: inputBlock)
        print("status: \(status.rawValue)")
    }
}

extension UnsafeMutableRawPointer {
    func mutable <T> () -> UnsafeMutablePointer<T> {
        return UnsafeMutablePointer<T>(OpaquePointer(self))
    }
}
