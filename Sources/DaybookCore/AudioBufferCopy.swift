import AVFoundation

extension AVAudioPCMBuffer {
    /// A copy of the buffer's frames that the caller owns, for keeping audio past the callback that
    /// delivered it (a live captioner's queue, a writer's). Nil when a buffer of the same format can't be
    /// made or the two don't have the same layout. The same for every capture path on both apps.
    public func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let input = source[index].mData, let output = destination[index].mData else { return nil }
            memcpy(output, input, Int(min(source[index].mDataByteSize, destination[index].mDataByteSize)))
        }
        return copy
    }
}
