// Subset of Web Audio for the Chorus web backend.
// The generator emits no inherited members, so each interface lists the members that Chorus calls.
// The JS host finds members by name, so the names here are the JS names.

interface Object {
  constructor();
  attribute float sampleRate;
  attribute DOMString latencyHint;
};

interface AudioContext {
  constructor();
  constructor(Object contextOptions);
  readonly attribute double currentTime;
  readonly attribute float sampleRate;
  readonly attribute DOMString state;
  readonly attribute AudioDestinationNode destination;
  undefined resume();
  undefined close();
  GainNode createGain();
  AudioBuffer createBuffer(unsigned long numberOfChannels, unsigned long length, float sampleRate);
  AudioBufferSourceNode createBufferSource();
};

interface AudioDestinationNode {
  readonly attribute unsigned long maxChannelCount;
};

interface AudioParam {
  attribute float value;
  AudioParam setValueAtTime(float value, double startTime);
  AudioParam linearRampToValueAtTime(float value, double endTime);
  AudioParam cancelScheduledValues(double cancelTime);
};

interface GainNode {
  readonly attribute AudioParam gain;
  AudioDestinationNode connect(AudioDestinationNode destinationNode);
  undefined disconnect();
};

interface AudioBuffer {
  undefined copyToChannel(Float32Array source, unsigned long channelNumber, unsigned long bufferOffset);
};

interface AudioBufferSourceNode {
  attribute AudioBuffer? buffer;
  GainNode connect(GainNode destinationNode);
  undefined start(double when);
  undefined stop(double when);
};

interface UserActivation {
  readonly attribute boolean hasBeenActive;
  readonly attribute boolean isActive;
};

namespace navigator {
  readonly attribute UserActivation? userActivation;
};

namespace globalThis {
  readonly attribute boolean AudioContext;
};

namespace document {
  readonly attribute boolean hidden;
};

namespace performance {
  double now();
};
