/* Original Citrus helper. Uses the public, dynamically loaded libvips C API.
 * Build: clang -O2 image-decoder.c -o bin/image-decoder
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

int main(int argc,char **argv) {
    if(argc!=3){fprintf(stderr,"Usage: image-decoder INPUT OUTPUT.png\n");return 2;}
    char executable[PATH_MAX],resolved[PATH_MAX],library[PATH_MAX];uint32_t length=sizeof(executable);
    if(_NSGetExecutablePath(executable,&length)!=0 || !realpath(executable,resolved)){perror("Executable path");return 1;}
    char *slash=strrchr(resolved,'/');if(!slash)return 1;*slash=0;
    if(snprintf(library,sizeof(library),"%s/../lib/libvips-cpp.8.18.7.dylib",resolved)>=(int)sizeof(library))return 1;
    void *handle=dlopen(library,RTLD_NOW|RTLD_LOCAL);
    if(!handle){fprintf(stderr,"Cannot load image codec: %s\n",dlerror());return 1;}
    int (*init)(const char*)=dlsym(handle,"vips_init");
    void* (*read_image)(const char*,...)=dlsym(handle,"vips_image_new_from_file");
    int (*write_image)(void*,const char*,...)=dlsym(handle,"vips_image_write_to_file");
    int (*autorot)(void*,void**,...)=dlsym(handle,"vips_autorot");
    int (*width)(void*)=dlsym(handle,"vips_image_get_width");
    int (*height)(void*)=dlsym(handle,"vips_image_get_height");
    void (*unref)(void*)=dlsym(handle,"g_object_unref");
    const char* (*error)(void)=dlsym(handle,"vips_error_buffer");
    void (*threads)(int)=dlsym(handle,"vips_concurrency_set");
    if(!init||!read_image||!write_image||!autorot||!width||!height||!unref||!error){fprintf(stderr,"Incomplete image codec API\n");return 1;}
    if(init(argv[0])!=0){fprintf(stderr,"%s\n",error());return 1;}
    if(threads)threads(2);
    void *input=read_image(argv[1],NULL),*rotated=NULL;
    if(!input){fprintf(stderr,"%s\n",error());return 1;}
    int w=width(input),h=height(input);
    if(w<=0||h<=0||(uint64_t)w*(uint64_t)h>150000000){fprintf(stderr,"Image dimensions exceed the pixel limit\n");unref(input);return 1;}
    if(autorot(input,&rotated,NULL)!=0){fprintf(stderr,"%s\n",error());unref(input);return 1;}
    int result=write_image(rotated,argv[2],NULL);
    if(result!=0)fprintf(stderr,"%s\n",error());
    unref(rotated);unref(input);return result==0 ? 0:1;
}
