#ifndef SOURCE_SOUND_ATOMICS_H
#define SOURCE_SOUND_ATOMICS_H

#include <stdint.h>

typedef struct SourceSoundAtomicUInt32 SourceSoundAtomicUInt32;

SourceSoundAtomicUInt32 *SourceSoundAtomicUInt32Create(uint32_t initialValue);
void SourceSoundAtomicUInt32Destroy(SourceSoundAtomicUInt32 *storage);
uint32_t SourceSoundAtomicUInt32LoadRelaxed(const SourceSoundAtomicUInt32 *storage);
void SourceSoundAtomicUInt32StoreRelaxed(SourceSoundAtomicUInt32 *storage, uint32_t value);
uint32_t SourceSoundAtomicUInt32LoadAcquire(const SourceSoundAtomicUInt32 *storage);
void SourceSoundAtomicUInt32StoreRelease(SourceSoundAtomicUInt32 *storage, uint32_t value);
uint32_t SourceSoundAtomicUInt32FetchAddRelaxed(SourceSoundAtomicUInt32 *storage, uint32_t value);

#endif
