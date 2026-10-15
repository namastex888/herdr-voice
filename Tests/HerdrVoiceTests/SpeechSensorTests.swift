import Testing
@testable import HerdrVoiceCore

/// The fallback speech sensor follows the gate's own onset and hangover rules on the echo-guarded level.
@Test func theLoudnessSensorStartsOnTheGatesOnsetAndStopsAfterItsHangover() {
    let sensor = LoudnessSensor()
    let onset = SpeechGate<String>.onsetChunks, hangover = SpeechGate<String>.hangoverChunks
    let starts = (0..<onset).map { _ in sensor.hear("", aboveEcho: true, loud: true) }
    #expect(starts.dropLast().allSatisfy { $0 == nil } && starts.last == true)
    #expect((0..<10).allSatisfy { _ in sensor.hear("", aboveEcho: true, loud: true) == nil })
    let stops = (0..<hangover).map { _ in sensor.hear("", aboveEcho: true, loud: false) }
    #expect(stops.dropLast().allSatisfy { $0 == nil } && stops.last == false)
}

@Test func theLoudnessSensorIgnoresAClickAndHerEcho() {
    let sensor = LoudnessSensor()
    let onset = SpeechGate<String>.onsetChunks
    // Shorter than an onset, again and again: never speech.
    for _ in 0..<20 {
        for _ in 0..<(onset - 1) { #expect(sensor.hear("", aboveEcho: true, loud: true) == nil) }
        #expect(sensor.hear("", aboveEcho: true, loud: false) == nil)
    }
    // Loud, but no louder than her own voice's echo: never speech.
    for _ in 0..<50 { #expect(sensor.hear("", aboveEcho: false, loud: true) == nil) }
}

@Test func aResetSensorStartsAfresh() {
    let sensor = LoudnessSensor()
    for _ in 0..<SpeechGate<String>.onsetChunks { _ = sensor.hear("", aboveEcho: true, loud: true) }
    sensor.reset()
    #expect(sensor.hear("", aboveEcho: true, loud: false) == nil, "a reset sensor has nothing to stop")
    let again = (0..<SpeechGate<String>.onsetChunks).map { _ in sensor.hear("", aboveEcho: true, loud: true) }
    #expect(again.last == true)
}
