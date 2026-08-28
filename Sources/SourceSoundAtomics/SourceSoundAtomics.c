#include "SourceSoundAtomics.h"

#include <stdatomic.h>
#include <stdlib.h>

struct SourceSoundAtomicUInt32 {
    _Atomic(uint32_t) value;
};

SourceSoundAtomicUInt32 *SourceSoundAtomicUInt32Create(uint32_t initialValue) {
    SourceSoundAtomicUInt32 *storage = malloc(sizeof(SourceSoundAtomicUInt32));
    if (storage == NULL) {
        return NULL;
    }
    atomic_init(&storage->value, initialValue);
    return storage;
}

void SourceSoundAtomicUInt32Destroy(SourceSoundAtomicUInt32 *storage) {
    free(storage);
}

uint32_t SourceSoundAtomicUInt32LoadRelaxed(const SourceSoundAtomicUInt32 *storage) {
    return atomic_load_explicit(&storage->value, memory_order_relaxed);
}

void SourceSoundAtomicUInt32StoreRelaxed(SourceSoundAtomicUInt32 *storage, uint32_t value) {
    atomic_store_explicit(&storage->value, value, memory_order_relaxed);
}

uint32_t SourceSoundAtomicUInt32LoadAcquire(const SourceSoundAtomicUInt32 *storage) {
    return atomic_load_explicit(&storage->value, memory_order_acquire);
}

void SourceSoundAtomicUInt32StoreRelease(SourceSoundAtomicUInt32 *storage, uint32_t value) {
    atomic_store_explicit(&storage->value, value, memory_order_release);
}

uint32_t SourceSoundAtomicUInt32FetchAddRelaxed(SourceSoundAtomicUInt32 *storage, uint32_t value) {
    return atomic_fetch_add_explicit(&storage->value, value, memory_order_relaxed);
}
