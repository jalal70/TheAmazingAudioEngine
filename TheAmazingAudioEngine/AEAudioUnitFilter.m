//
//  AEAudioUnitFilter.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 05/02/2013.
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#import "AEAudioUnitFilter.h"

#define checkResult(result,operation) (_checkResult((result),(operation),strrchr(__FILE__, '/')+1,__LINE__))
static inline BOOL _checkResult(OSStatus result, const char *operation, const char* file, int line) {
    if ( result != noErr ) {
        int fourCC = CFSwapInt32HostToBig(result);
        NSLog(@"%s:%d: %s result %d %08X %4.4s\n", file, line, operation, (int)result, (int)result, (char*)&fourCC);
        return NO;
    }
    return YES;
}

@interface AEAudioUnitFilter () {
    AEAudioController *_audioController;
    AudioComponentDescription _componentDescription;
    AUNode _node;
    AudioUnit _audioUnit;
    AUNode _inConverterNode;
    AudioUnit _inConverterUnit;
    AUNode _outConverterNode;
    AudioUnit _outConverterUnit;
    AUGraph _audioGraph;
    AEAudioControllerFilterProducer _currentProducer;
    void *_currentProducerToken;
}
@end

@implementation AEAudioUnitFilter

- (id)initWithComponentDescription:(AudioComponentDescription)audioComponentDescription
                   audioController:(AEAudioController*)audioController
                             error:(NSError**)error {
    if ( !(self = [super init]) ) return nil;

    // Create the node, and the audio unit
    _audioController = audioController;
    _componentDescription = audioComponentDescription;
    _audioGraph = audioController.audioGraph;
	
    if ( ![self setup:error] ) {
        [self release];
        return nil;
    }
    
    return self;
}

- (BOOL)setup:(NSError**)error {
    
    OSStatus result;
    if ( !checkResult(result=AUGraphAddNode(_audioGraph, &_componentDescription, &_node), "AUGraphAddNode") ||
        !checkResult(result=AUGraphNodeInfo(_audioGraph, _node, NULL, &_audioUnit), "AUGraphNodeInfo") ) {
        
        if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Couldn't initialise audio unit" forKey:NSLocalizedDescriptionKey]];
        return NO;
    }
    
    // Try to set the output audio description
    AudioStreamBasicDescription audioDescription = _audioController.audioDescription;
    result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription));
    if ( result == kAudioUnitErr_FormatNotSupported ) {
        // The audio description isn't supported. Assign modified default audio description, and create an audio converter.
        AudioStreamBasicDescription defaultAudioDescription;
        UInt32 size = sizeof(defaultAudioDescription);
        result = AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, &size);
        defaultAudioDescription.mSampleRate = audioDescription.mSampleRate;
        AEAudioStreamBasicDescriptionSetChannelsPerFrame(&defaultAudioDescription, audioDescription.mChannelsPerFrame);
        if ( !checkResult(result=AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, size), "AudioUnitSetProperty") ) {
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Incompatible audio format" forKey:NSLocalizedDescriptionKey]];
            return NO;
        }
        
        AudioComponentDescription audioConverterDescription = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
        
        if ( !checkResult(result=AUGraphAddNode(_audioGraph, &audioConverterDescription, &_outConverterNode), "AUGraphAddNode") ||
            !checkResult(result=AUGraphNodeInfo(_audioGraph, _outConverterNode, NULL, &_outConverterUnit), "AUGraphNodeInfo") ||
            !checkResult(result=AUGraphConnectNodeInput(_audioGraph, _node, 0, _outConverterNode, 0), "AUGraphConnectNodeInput") ||
            !checkResult(result=AudioUnitSetProperty(_outConverterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &defaultAudioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
            !checkResult(result=AudioUnitSetProperty(_outConverterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &audioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) {
            
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Couldn't setup converter audio unit" forKey:NSLocalizedDescriptionKey]];
            return NO;
        }
    }
    
    // Try to set the input audio description
    audioDescription = _audioController.audioDescription;
    result = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioDescription, sizeof(AudioStreamBasicDescription));
    if ( result == kAudioUnitErr_FormatNotSupported ) {
        // The audio description isn't supported. Assign modified default audio description, and create an audio converter.
        AudioStreamBasicDescription defaultAudioDescription;
        UInt32 size = sizeof(defaultAudioDescription);
        result = AudioUnitGetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &defaultAudioDescription, &size);
        defaultAudioDescription.mSampleRate = audioDescription.mSampleRate;
        AEAudioStreamBasicDescriptionSetChannelsPerFrame(&defaultAudioDescription, audioDescription.mChannelsPerFrame);
        if ( !checkResult(result=AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &defaultAudioDescription, size), "AudioUnitSetProperty") ) {
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Incompatible audio format" forKey:NSLocalizedDescriptionKey]];
            return NO;
        }
        
        AudioComponentDescription audioConverterDescription = AEAudioComponentDescriptionMake(kAudioUnitManufacturer_Apple, kAudioUnitType_FormatConverter, kAudioUnitSubType_AUConverter);
        
        if ( !checkResult(result=AUGraphAddNode(_audioGraph, &audioConverterDescription, &_inConverterNode), "AUGraphAddNode") ||
            !checkResult(result=AUGraphNodeInfo(_audioGraph, _inConverterNode, NULL, &_inConverterUnit), "AUGraphNodeInfo") ||
            !checkResult(result=AUGraphConnectNodeInput(_audioGraph, _inConverterNode, 0, _node, 0), "AUGraphConnectNodeInput") ||
            !checkResult(result=AudioUnitSetProperty(_inConverterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &defaultAudioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ||
            !checkResult(result=AudioUnitSetProperty(_inConverterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &audioDescription, sizeof(AudioStreamBasicDescription)), "AudioUnitSetProperty(kAudioUnitProperty_StreamFormat)") ) {
            
            if ( error ) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:[NSDictionary dictionaryWithObject:@"Couldn't setup converter audio unit" forKey:NSLocalizedDescriptionKey]];
            return NO;
        }
    }
    
    // Set the audio unit's input callback
    // Setup render callback struct
    AURenderCallbackStruct rcbs;
    rcbs.inputProc = &audioUnitRenderCallback;
    rcbs.inputProcRefCon = self;
    checkResult(AudioUnitSetProperty(_inConverterUnit ? _inConverterUnit : _audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &rcbs, sizeof(rcbs)),
                "AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback)");
    
    // Attempt to set the max frames per slice
    UInt32 maxFPS = 4096;
    AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
    
    
    checkResult(AUGraphUpdate(_audioGraph, NULL), "AUGraphUpdate");
    
    checkResult(AudioUnitInitialize(_audioUnit), "AudioUnitInitialize");
    
    if ( _inConverterUnit ) {
        checkResult(AudioUnitInitialize(_inConverterUnit), "AudioUnitInitialize");
        AudioUnitSetProperty(_inConverterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
    }
    
    if ( _outConverterUnit ) {
        checkResult(AudioUnitInitialize(_outConverterUnit), "AudioUnitInitialize");
        AudioUnitSetProperty(_outConverterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, sizeof(maxFPS));
    }
    
    
    return YES;
}

-(void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AEAudioControllerDidRecreateGraphNotification object:_audioController];
    
    if ( _node ) {
        checkResult(AUGraphRemoveNode(_audioGraph, _node), "AUGraphRemoveNode");
    }
    if ( _outConverterNode ) {
        checkResult(AUGraphRemoveNode(_audioGraph, _outConverterNode), "AUGraphRemoveNode");
    }
    if ( _inConverterNode ) {
        checkResult(AUGraphRemoveNode(_audioGraph, _inConverterNode), "AUGraphRemoveNode");
    }
    
    checkResult(AUGraphUpdate(_audioGraph, NULL), "AUGraphUpdate");
    
    [super dealloc];
}

-(AudioUnit)audioUnit {
    return _audioUnit;
}

static OSStatus filterCallback(id                        filter,
                               AEAudioController        *audioController,
                               AEAudioControllerFilterProducer producer,
                               void                     *producerToken,
                               const AudioTimeStamp     *time,
                               UInt32                    frames,
                               AudioBufferList          *audio) {
    AEAudioUnitFilter *THIS = (AEAudioUnitFilter*)filter;
    
    THIS->_currentProducer = producer;
    THIS->_currentProducerToken = producerToken;
    
    AudioUnitRenderActionFlags flags = 0;
    checkResult(AudioUnitRender(THIS->_outConverterUnit ? THIS->_outConverterUnit : THIS->_audioUnit, &flags, time, 0, frames, audio), "AudioUnitRender");
    
    return noErr;
}

-(AEAudioControllerFilterCallback)filterCallback {
    return filterCallback;
}

static OSStatus audioUnitRenderCallback(void                       *inRefCon,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp       *inTimeStamp,
                                        UInt32                      inBusNumber,
                                        UInt32                      inNumberFrames,
                                        AudioBufferList            *ioData) {
    AEAudioUnitFilter *THIS = (AEAudioUnitFilter*)inRefCon;
    return THIS->_currentProducer(THIS->_currentProducerToken, ioData, &inNumberFrames);
}

- (void)didRecreateGraph:(NSNotification*)notification {
    _node = 0;
    _audioUnit = NULL;
    _inConverterNode = 0;
    _inConverterUnit = NULL;
    _outConverterNode = 0;
    _outConverterUnit = NULL;
    _audioGraph = _audioController.audioGraph;
    [self setup:NULL];
}

@end
