#include <stdint.h>
#include <stddef.h>
typedef struct G10Decoder G10Decoder;
G10Decoder *g10_create(int vp9, unsigned width, unsigned height);
void g10_destroy(G10Decoder *decoder);
int g10_decode(G10Decoder *decoder, const uint8_t *color, size_t color_size,
               const uint8_t *alpha, size_t alpha_size, uint8_t *rgba, size_t capacity);
const char *g10_version(void);
