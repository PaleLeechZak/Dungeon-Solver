package game

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

import "../sound"

// Playback through SDL. What to play and how loud is decided in src/sound;
// this only loads the files of the manifest and pushes samples at a pool of
// voices. Sound is never essential: if there is no audio device, or a file
// will not load, the game carries on without it.

Audio_Clip :: struct {
	spec:   sdl.AudioSpec,
	data:   [^]u8, // owned by SDL
	length: u32,
}

Audio :: struct {
	device: sdl.AudioDeviceID,
	voices: []^sdl.AudioStream,
	clips:  []Audio_Clip, // one per sound of the bank, in the bank's order
	next:   int, // voice to steal when all are busy
	music:  ^sdl.AudioStream, // nil unless the manifest lists music
}

audio_init :: proc(a: ^Audio, bank: ^sound.Bank, voices: int) {
	if !sdl.InitSubSystem({.AUDIO}) {
		fmt.eprintfln("no sound: %s", sdl.GetError())
		return
	}
	a.device = sdl.OpenAudioDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, nil)
	if a.device == 0 {
		fmt.eprintfln("no sound: cannot open an audio device: %s", sdl.GetError())
		return
	}

	// Only what the manifest lists is ever loaded.
	a.clips = make([]Audio_Clip, len(bank.sounds))
	for s, i in bank.sounds {
		clip := &a.clips[i]
		path := strings.clone_to_cstring(s.path, context.temp_allocator)
		if !sdl.LoadWAV(path, &clip.spec, &clip.data, &clip.length) {
			fmt.eprintfln("sound '%s' will be silent: %s", s.id, sdl.GetError())
			clip^ = {}
		}
	}

	// Each voice is retuned to its clip's format when it starts playing.
	spec := sdl.AudioSpec {
		format   = .S16,
		channels = 2,
		freq     = 44100,
	}
	pool := make([dynamic]^sdl.AudioStream)
	for _ in 0 ..< voices {
		stream := sdl.CreateAudioStream(&spec, &spec)
		if stream == nil || !sdl.BindAudioStream(a.device, stream) {
			sdl.DestroyAudioStream(stream)
			break
		}
		append(&pool, stream)
	}
	a.voices = pool[:]
	if len(a.voices) == 0 {
		fmt.eprintfln("no sound: cannot create audio streams: %s", sdl.GetError())
	}

	// Music, when the manifest has any, plays on a stream of its own.
	if len(bank.music) > 0 {
		a.music = sdl.CreateAudioStream(&spec, &spec)
		if a.music != nil && !sdl.BindAudioStream(a.device, a.music) {
			sdl.DestroyAudioStream(a.music)
			a.music = nil
		}
	}
}

// Bytes of music left to play below which the next piece is queued: about
// half a second, so one frame's hiccup never leaves a gap.
MUSIC_LOW_WATER :: 44100 * 4 / 2

// Keeps the music going at the mixer's volume. Call once a frame. Each piece
// is a seamless loop, so queueing them end to end is all the looping needed;
// the bank's playlist says which comes next.
audio_update :: proc(a: ^Audio, bank: ^sound.Bank, mixer: sound.Mixer) {
	if a.music == nil {
		return
	}
	_ = sdl.SetAudioStreamGain(a.music, sound.music_gain(mixer))
	if sdl.GetAudioStreamQueued(a.music) >= MUSIC_LOW_WATER {
		return
	}
	next, ok := sound.music_next(bank)
	if !ok || next >= len(a.clips) || a.clips[next].data == nil {
		return
	}
	clip := a.clips[next]
	spec := clip.spec
	if sdl.SetAudioStreamFormat(a.music, &spec, nil) {
		_ = sdl.PutAudioStreamData(a.music, clip.data, i32(clip.length))
	}
}
audio_destroy :: proc(a: ^Audio) {
	for stream in a.voices {
		sdl.DestroyAudioStream(stream)
	}
	sdl.DestroyAudioStream(a.music)
	for clip in a.clips {
		sdl.free(clip.data)
	}
	if a.device != 0 {
		sdl.CloseAudioDevice(a.device)
	}
	delete(a.voices)
	delete(a.clips)
	a^ = {}
}

// Starts a sound on a free voice, or on the one that has been playing
// longest when all are busy.
audio_play :: proc(a: ^Audio, request: sound.Request) {
	if len(a.voices) == 0 || request.sound < 0 || request.sound >= len(a.clips) {
		return
	}
	clip := a.clips[request.sound]
	if clip.data == nil {
		return
	}
	voice := -1
	for stream, i in a.voices {
		if sdl.GetAudioStreamQueued(stream) == 0 {
			voice = i
			break
		}
	}
	if voice < 0 {
		voice = a.next
		a.next = (a.next + 1) % len(a.voices)
		_ = sdl.ClearAudioStream(a.voices[voice])
	}
	stream := a.voices[voice]
	spec := clip.spec
	if !sdl.SetAudioStreamFormat(stream, &spec, nil) {
		return
	}
	_ = sdl.SetAudioStreamGain(stream, request.gain)
	if sdl.PutAudioStreamData(stream, clip.data, i32(clip.length)) {
		// Nothing more is coming for this clip; let its tail play out.
		_ = sdl.FlushAudioStream(stream)
	}
}
