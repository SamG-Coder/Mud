// Mud: all material, UV transport, normal editing, simulation and pixels live
// here. Field float4 = mud thickness above concrete (m), surface water depth
// (m), transported U, V. Closed boundaries; water flux is donor-limited and
// pairwise conservative.
__device__ float sat(float x) { return fminf(1.0f, fmaxf(0.0f, x)); }
__device__ float3 add(float3 a, float3 b) {
  return make_float3(a.x + b.x, a.y + b.y, a.z + b.z);
}
__device__ float3 mul(float3 a, float b) {
  return make_float3(a.x * b, a.y * b, a.z * b);
}
__device__ float dot3(float3 a, float3 b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}
__device__ float3 norm(float3 a) {
  return mul(a, 1.0f / sqrtf(fmaxf(dot3(a, a), 0.000001f)));
}
__device__ int cell(int x, int z, int n) {
  return min(n - 1, max(0, z)) * n + min(n - 1, max(0, x));
}
__device__ float4 sample(const float4 *a, float x, float z, int n) {
  float u =
      fminf((float)n - 1.001f, fmaxf(0.0f, (x + 2.5f) * (float)(n - 1) / 5.0f));
  float v =
      fminf((float)n - 1.001f, fmaxf(0.0f, (z + 2.5f) * (float)(n - 1) / 5.0f));
  int ix = (int)u;
  int iz = (int)v;
  float fx = u - (float)ix;
  float fz = v - (float)iz;
  float4 p = a[cell(ix, iz, n)];
  float4 q = a[cell(ix + 1, iz, n)];
  float4 r = a[cell(ix, iz + 1, n)];
  float4 s = a[cell(ix + 1, iz + 1, n)];
  return p * (1.0f - fx) * (1.0f - fz) + q * fx * (1.0f - fz) +
         r * (1.0f - fx) * fz + s * fx * fz;
}
__device__ float height(const float4 *a, const float4 *mixture, float x,
                        float z, int n) {
  float4 p = sample(a, x, z, n);
  return p.x + p.y + sample(mixture, x, z, n).y;
}
__device__ unsigned int hash(unsigned int x) {
  x ^= x >> 16;
  x *= 2146121005u;
  x ^= x >> 15;
  x *= 2221713035u;
  x ^= x >> 16;
  return x;
}
__device__ float rand2(int x, int y) {
  return (float)(hash((unsigned int)x * 1597334677u +
                      (unsigned int)y * 3812015801u) &
                 16777215u) /
         16777216.0f;
}
__device__ float noise(float x, float y) {
  int ix = (int)floorf(x);
  int iy = (int)floorf(y);
  float u = x - floorf(x);
  float v = y - floorf(y);
  u = u * u * (3.0f - 2.0f * u);
  v = v * v * (3.0f - 2.0f * v);
  return rand2(ix, iy) * (1.0f - u) * (1.0f - v) +
         rand2(ix + 1, iy) * u * (1.0f - v) +
         rand2(ix, iy + 1) * (1.0f - u) * v + rand2(ix + 1, iy + 1) * u * v;
}
__device__ float grain(float u, float v) {
  return noise(u * 34.0f, v * 34.0f) * 0.5f +
         noise(u * 93.0f, v * 93.0f) * 0.3f +
         noise(u * 211.0f, v * 211.0f) * 0.2f;
}
// Three 4096-square material textures, packed to 32 bits per texel.
// Detail: 8 bits, signed micro-height: 16 bits, roughness: 8 bits.
// Complete mip chains filter the microscopic grain at oblique/distant views.
__device__ unsigned int packTex(float4 p) {
  unsigned int colour=(unsigned int)(sat(p.x/1.5f)*255.0f+.5f);
  unsigned int h=(unsigned int)(sat((p.y+.008f)/.016f)*65535.0f+.5f);
  unsigned int rough=(unsigned int)(sat(p.z)*255.0f+.5f);
  return colour | (h<<8) | (rough<<24);
}
__device__ float4 unpackTex(unsigned int p) {
  return make_float4((float)(p&255u)/255.0f*1.5f,
    (float)((p>>8)&65535u)/65535.0f*.016f-.008f,
    (float)(p>>24)/255.0f,0.0f);
}
__global__ void texture_generate(unsigned int *textureMap, int textureSize,
                                 int chainLength, int seed) {
  int i=(int)((blockIdx.y*gridDim.x+blockIdx.x)*blockDim.x+threadIdx.x);
  int area=textureSize*textureSize;
  if(i>=area*3) return;
  int kind=i/area, pixel=i%area;
  float x=(float)(pixel%textureSize)*5.0f/(float)textureSize;
  float z=(float)(pixel/textureSize)*5.0f/(float)textureSize;
  x+=(float)seed*.137f+(float)kind*17.3f;
  z-=(float)seed*.137f-(float)kind*11.7f;
  float wx=x+(noise(x*3.0f,z*3.0f)-.5f)*.11f;
  float wz=z+(noise(x*3.0f+7.0f,z*3.0f)-.5f)*.11f;
  float broad=noise(wx*5.0f,wz*5.0f);
  float fine=noise(wx*170.0f,wz*170.0f);
  float warp=noise(wx*8.0f+9.0f,wz*8.0f)*1.4f;
  float vein=powf(sat(1.0f-fabsf(sinf(wx*95.0f+wz*21.0f+warp*12.0f))),7.0f);
  float folds=powf(1.0f-fabsf(noise(wx*22.0f,wz*22.0f)*2.0f-1.0f),5.0f);
  float pores=sat((noise(wx*470.0f,wz*470.0f)-.62f)*6.0f);
  float detail=.70f+broad*.25f+fine*.18f;
  float micro=folds*.0018f+vein*.0013f+fine*.00030f-pores*.00035f;
  float rough=.17f+broad*.13f;
  if(kind==1) {
    micro=folds*.0025f+vein*.0006f+fine*.00018f-pores*.0003f;
    rough=.12f+broad*.11f;
    detail=.72f+broad*.30f+fine*.09f;
  }
  if(kind==2) {
    float clumps=powf(noise(wx*71.0f,wz*71.0f),3.0f);
    micro=clumps*.0022f+fine*.00075f-pores*.0006f;
    rough=.38f+broad*.20f;
    detail=.55f+broad*.32f+fine*.35f;
  }
  textureMap[kind*chainLength+pixel]=packTex(make_float4(detail,micro,rough,0.0f));
}
__global__ void texture_mip(unsigned int *textureMap, int inputSize,
                            int inputOffset, int outputOffset, int chainLength) {
  int i=(int)((blockIdx.y*gridDim.x+blockIdx.x)*blockDim.x+threadIdx.x);
  int size=inputSize/2, area=size*size;
  if(i>=area*3) return;
  int kind=i/area, pixel=i%area;
  int j=kind*chainLength+inputOffset+(pixel/size)*2*inputSize+(pixel%size)*2;
  float4 p=(unpackTex(textureMap[j])+unpackTex(textureMap[j+1])+
            unpackTex(textureMap[j+inputSize])+unpackTex(textureMap[j+inputSize+1]))*.25f;
  textureMap[kind*chainLength+outputOffset+pixel]=packTex(p);
}
__device__ float4 atlas(const unsigned int *textureMap, int kind, float u,
                        float v, int size, int chainLength, int level) {
  int offset=kind*chainLength;
  for(int k=0;k<12;k++) {
    if(k<level) {offset+=size*size; size=max(1,size/2);}
  }
  float x=(u/5.0f-floorf(u/5.0f))*(float)size;
  float y=(v/5.0f-floorf(v/5.0f))*(float)size;
  int ix=(int)x, iy=(int)y;
  float fx=x-(float)ix, fy=y-(float)iy;
  int jx=(ix+1)%size, jy=(iy+1)%size;
  return unpackTex(textureMap[offset+iy*size+ix])*(1.0f-fx)*(1.0f-fy)+
         unpackTex(textureMap[offset+iy*size+jx])*fx*(1.0f-fy)+
         unpackTex(textureMap[offset+jy*size+ix])*(1.0f-fx)*fy+
         unpackTex(textureMap[offset+jy*size+jx])*fx*fy;
}
__device__ float4 layeredAtlas(const unsigned int *maps, float u, float v,
                               int size, int chainLength, int level,
                               float4 weights, float4 swipe) {
  float4 a=atlas(maps,0,u,v,size,chainLength,level);
  float4 b=atlas(maps,1,u,v,size,chainLength,level);
  float4 c=atlas(maps,2,u,v,size,chainLength,level);
  float direction=sqrtf(swipe.x*swipe.x+swipe.y*swipe.y);
  float tx=swipe.x/fmaxf(direction,.001f), tz=swipe.y/fmaxf(direction,.001f);
  float4 streak=atlas(maps,1,(u*tx+v*tz)*.22f,(-u*tz+v*tx)*2.4f,
                       size,chainLength,min(12,level+1));
  float streakAmount=sat(swipe.z*.45f)*sat(direction*4.0f);
  float4 result=a*weights.x+b*weights.y+c*weights.z;
  return result*(1.0f-streakAmount)+streak*streakAmount;
}
__device__ float4 composition(float x,float z,int seed) {
  float off=(float)seed*.137f;
  float a=.16f+powf(.12f+noise(x*1.7f+off,z*1.7f),2.0f)*.75f;
  float b=.05f+powf(.12f+noise(x*1.4f+13.0f,z*1.4f+off),2.0f)*.65f;
  float c=powf(sat((noise(x*4.8f-8.0f,z*4.8f+off)-.35f)*1.9f),2.0f)*.22f;
  float sum=fmaxf(a+b+c,.0001f);
  return make_float4(a/sum,b/sum,c/sum,0.0f);
}
__global__ void surface_initialize(float4 *colours,float4 *coordinates,
                                   float4 *swipes,int detailN,int seed) {
  int i=(int)(blockIdx.x*blockDim.x+threadIdx.x);
  if(i>=detailN*detailN) return;
  float x=(float)(i%detailN)*5.0f/(float)(detailN-1)-2.5f;
  float z=(float)(i/detailN)*5.0f/(float)(detailN-1)-2.5f;
  colours[i]=composition(x,z,seed);
  coordinates[i]=make_float4(x,z,0.0f,0.0f);
  swipes[i]=make_float4(0.0f,0.0f,0.0f,0.0f);
}
// Fine material advection is independent of the coarser volume solver.
// The drive contains the displacement integrated over every physics substep.
__global__ void surface_advect(const float4 *field,const float4 *drive,const float4 *objects,
  const float4 *coloursIn,const float4 *coordinatesIn,const float4 *swipesIn,
  float4 *coloursOut,float4 *coordinatesOut,float4 *swipesOut,
  int n,int detailN,float dt,int brush,float bx,float bz,float radius,
  float amount,float brushVX,float brushVZ,int clayType,int seed) {
  int i=(int)(blockIdx.x*blockDim.x+threadIdx.x);
  if(i>=detailN*detailN) return;
  float x=(float)(i%detailN)*5.0f/(float)(detailN-1)-2.5f;
  float z=(float)(i/detailN)*5.0f/(float)(detailN-1)-2.5f;
  float4 move=sample(drive,x,z,n);
  // The upper material shears past the depth-averaged bulk. Transport the
  // visible clay film with contact velocity even when a bank resists volume flow.
  float dx=x-bx,dz=z-bz;
  float weight=expf(-(dx*dx+dz*dz)/(radius*radius)*3.0f);
  float2 skin=make_float2(0.0f,0.0f);
  for(int j=0;j<4;j++) {
    float4 body=objects[j*2],velocity=objects[j*2+1];
    float px=x-body.x,pz=z-body.z;
    float r=sqrtf(px*px+pz*pz)/body.w;
    if(j==3) r=fmaxf(fabsf(px),fabsf(pz))/body.w;
    float depth=sample(field,body.x,body.z,n).x;
    float touch=sat((depth+body.w-body.y)/fmaxf(.015f,body.w*.45f));
    float influence=expf(-r*r*1.7f)*touch*.65f;
    skin.x+=velocity.x*influence; skin.y+=velocity.z*influence;
  }
  if(brush==8) {skin.x+=brushVX*weight*amount*.55f;skin.y+=brushVZ*weight*amount*.55f;}
  float skinSpeed=sqrtf(skin.x*skin.x+skin.y*skin.y);
  skin*=fminf(1.0f,4.0f/fmaxf(skinSpeed,.00001f))*sat(sample(field,x,z,n).x*500.0f);
  move.x+=skin.x*dt;move.y+=skin.y*dt;

  float speed=sqrtf(move.x*move.x+move.y*move.y)/fmaxf(dt,.00001f);
  float sx=x-move.x,sz=z-move.y;
  float4 c=sample(coloursIn,sx,sz,detailN);
  float4 coord=sample(coordinatesIn,sx,sz,detailN);
  float4 sw=sample(swipesIn,sx,sz,detailN);
  float len=sqrtf(move.x*move.x+move.y*move.y);
  float tx=move.x/fmaxf(len,.000001f),tz=move.y/fmaxf(len,.000001f);
  float activity=sat(move.z*.22f);
  float reach=fminf(.09f,.012f+speed*.026f);
  // Anisotropic mixing spreads pigment along the swipe instead of random recolouring.
  float4 streak=(sample(coloursIn,sx+tx*reach,sz+tz*reach,detailN)+
                 sample(coloursIn,sx-tx*reach,sz-tz*reach,detailN))*.5f;
  c=c*(1.0f-activity)+streak*activity;
  c.w=sat(c.w+move.z*.18f);
  float alignment=sat(len*18.0f+move.w*.5f);
  sw.x=sw.x*(1.0f-alignment)+tx*alignment;
  sw.y=sw.y*(1.0f-alignment)+tz*alignment;
  sw.z=sat(sw.z+move.z*.12f);
  sw.w=fmaxf(sw.w*expf(-dt*1.8f),sat(speed/3.0f));
  if(brush==4) {
    coord.x-=brushVX*weight*dt*amount*.85f;
    coord.y-=brushVZ*weight*dt*amount*.85f;
  }
  if(brush==5) {
    float p=1.0f-expf(-weight*dt*amount*28.0f);
    c.x=c.x*(1.0f-p)+(clayType==0?p:0.0f);
    c.y=c.y*(1.0f-p)+(clayType==1?p:0.0f);
    c.z=c.z*(1.0f-p)+(clayType==2?p:0.0f);
  }
  if(brush==6) {
    coord.z=fminf(.8f,fmaxf(-.8f,coord.z+dx/radius*weight*dt*amount*3.0f));
    coord.w=fminf(.8f,fmaxf(-.8f,coord.w+dz/radius*weight*dt*amount*3.0f));
  }
  if(brush==7) {
    float erase=sat(weight*dt*amount*5.0f);
    coord.z*=1.0f-erase; coord.w*=1.0f-erase;
    float4 original=composition(coord.x,coord.y,seed);
    c=c*(1.0f-erase)+original*erase;
  }
  float total=fmaxf(c.x+c.y+c.z,.000001f);
  c.x/=total;c.y/=total;c.z/=total;
  coloursOut[i]=c; coordinatesOut[i]=coord; swipesOut[i]=sw;
}
__global__ void surface_clear(float4 *drive,int n) {
  int i=(int)(blockIdx.x*blockDim.x+threadIdx.x);
  if(i<n*n) drive[i]=make_float4(0.0f,0.0f,0.0f,0.0f);
}
__device__ float contact(const float4 *field, float4 p, float x, float z,
                         int n) {
  float h = sample(field, x, z, n).x;
  return sat((h + p.w - p.y) / fmaxf(0.015f, p.w * 0.45f));
}
__device__ float pressure(const float4 *field, const float4 *objects, float x,
                          float z, int n) {
  float result=0.0f;
  float h=sample(field,x,z,n).x;
  for(int j=0;j<4;j++) {
    float4 p=objects[j*2];
    float dx=x-p.x, dz=z-p.z;
    float rr=dx*dx+dz*dz;
    float bottom=1000.0f;
    if(j==3) {
      if(fmaxf(fabsf(dx),fabsf(dz))<p.w) bottom=p.y-p.w;
    } else if(rr<p.w*p.w) bottom=p.y-sqrtf(p.w*p.w-rr);
    // Actual collider intrusion pushes displaced soil out to the rim.
    result+=fmaxf(0.0f,h-bottom)*6.0f;
  }
  return result;
}
__device__ float2 shear(const float4 *field, const float4 *objects, float x,
                        float z, int n) {
  float2 result = make_float2(0.0f, 0.0f);
  for (int j = 0; j < 4; j++) {
    float4 p = objects[j * 2];
    float4 v = objects[j * 2 + 1];
    float dx = x - p.x;
    float dz = z - p.z;
    float r = sqrtf(dx * dx + dz * dz) / p.w;
    if (j == 3)
      r = fmaxf(fabsf(dx), fabsf(dz)) / p.w;
    float w = expf(-r * r * 1.7f) * contact(field, p, p.x, p.z, n) * 0.95f;
    result.x += v.x * w;
    result.y += v.z * w;
  }
  return result;
}
// Yielded shallow-layer flow: tau = rho*g*h*headGradient. Herschel-Bulkley
// shear rate above yield, zero creep below yield. Coefficients are artistic.
__device__ float plasticFlow(float drive, float depth, float spacing,
                             float dt, float yieldStress, float rate) {
  float stress = fmaxf(0.0f, drive) / spacing * 1450.0f * 9.81f * depth;
  float excess = fmaxf(0.0f, stress-yieldStress);
  float gamma = fminf(40.0f, powf(excess/90.0f, 1.0f/.65f));
  float physical = .5f*depth*depth*gamma*dt/spacing;
  // Limit each face transfer to avoid explicit nonlinear diffusion ringing.
  return fminf(physical, fmaxf(0.0f,drive)*fminf(.10f,dt*rate));
}
// Conservative pressure + tangential transport: soil is pushed ahead of a body,
// pulled into a smear, and piles up. Zero thickness exposes the rigid concrete.
__global__ void mud_flux(const float4 *field, const float4 *objects,
                         float4 *flux, const float4 *mixture, const float *structure, int n, float dt,
                         float softness, int brush, float bx, float bz,
                         float radius, float brushVX, float brushVZ,
                         float amount) {
  int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
  if (i >= n * n)
    return;
  int ix = i % n;
  int iz = i / n;
  float spacing = 5.0f / (float)(n - 1);
  float x = (float)ix * spacing - 2.5f;
  float z = (float)iz * spacing - 2.5f;
  float contact = pressure(field, objects, x, z, n);
  float depth = fmaxf(field[i].x, .000001f);
  float moisture = sat(mixture[i].x / fmaxf(depth*.35f,.000001f));
  float yieldStress = (120.0f+(1.0f-softness)*1200.0f) *
                      (1.0f-moisture*.55f) * (.20f+.80f*structure[i]);
  float2 velocity = shear(field, objects, x, z, n);
  if (brush == 8) {
    float weight = expf(-((x - bx) * (x - bx) + (z - bz) * (z - bz)) /
                        (radius * radius) * 3.0f);
    velocity.x += brushVX * weight * 0.95f * amount;
    velocity.y += brushVZ * weight * 0.95f * amount;
  }
  // Finite tangential traction cannot keep forcing material up an arbitrarily
  // steep bank. Limit uphill entrainment before conservative donor limiting.
  // Viscoplastic slip: tool speed can exceed the bulk clay velocity.
  // Saturating entrainment prevents a fast swipe behaving like a conveyor.
  float speed=sqrtf(velocity.x*velocity.x+velocity.y*velocity.y);
  velocity = velocity / (1.0f+speed/1.8f);
  float advect = dt / spacing * field[i].x;
  float a = 0.0f;
  float b = 0.0f;
  float c = 0.0f;
  float d = 0.0f;
  if (ix > 0)
    a = plasticFlow(field[i].x-field[i-1].x,depth,spacing,dt,yieldStress,48.0f)
        + plasticFlow(contact-pressure(field,objects,x-spacing,z,n),depth,spacing,dt,yieldStress,3.0f)
        + fmaxf(0.0f,-velocity.x)*advect *
          sat(1.0f-fmaxf(0.0f,field[i-1].x-field[i].x)/(spacing*.65f));
  if (ix < n-1)
    b = plasticFlow(field[i].x-field[i+1].x,depth,spacing,dt,yieldStress,48.0f)
        + plasticFlow(contact-pressure(field,objects,x+spacing,z,n),depth,spacing,dt,yieldStress,3.0f)
        + fmaxf(0.0f,velocity.x)*advect *
          sat(1.0f-fmaxf(0.0f,field[i+1].x-field[i].x)/(spacing*.65f));
  if (iz > 0)
    c = plasticFlow(field[i].x-field[i-n].x,depth,spacing,dt,yieldStress,48.0f)
        + plasticFlow(contact-pressure(field,objects,x,z-spacing,n),depth,spacing,dt,yieldStress,3.0f)
        + fmaxf(0.0f,-velocity.y)*advect *
          sat(1.0f-fmaxf(0.0f,field[i-n].x-field[i].x)/(spacing*.65f));
  if (iz < n-1)
    d = plasticFlow(field[i].x-field[i+n].x,depth,spacing,dt,yieldStress,48.0f)
        + plasticFlow(contact-pressure(field,objects,x,z+spacing,n),depth,spacing,dt,yieldStress,3.0f)
        + fmaxf(0.0f,velocity.y)*advect *
          sat(1.0f-fmaxf(0.0f,field[i+n].x-field[i].x)/(spacing*.65f));
  float scale =
      fminf(1.0f, fmaxf(0.0f, field[i].x) / fmaxf(a + b + c + d, 0.0000001f));
  flux[i] = make_float4(a, b, c, d) * scale;
}
__global__ void initialize(float4 *field, float4 *objects, float4 *material,
                           float4 *mixture, float4 *residue, float *structure, float4 *drive, int n, float water,
                           float thickness, int seed) {
  int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
  if (i >= n * n)
    return;
  float x = (float)(i % n) * 5.0f / (float)(n - 1) - 2.5f;
  float z = (float)(i / n) * 5.0f / (float)(n - 1) - 2.5f;
  float offset = (float)seed * 0.137f;
  float rx = fmaxf(0.0f, fabsf(x) - 1.2f);
  float rz = fmaxf(0.0f, fabsf(z) - 1.2f);
  float edge = 1.05f - sqrtf(rx * rx + rz * rz);
  float mask =
      sat((edge - 0.20f - (noise(x * 7.0f + offset, z * 7.0f) - 0.5f) * 0.13f) /
          0.12f);
  float variation = 1.0f + (noise(x * 3.0f + offset, z * 3.0f) - 0.5f) * 0.055f;
  float h = thickness * variation * mask;
  float puddle1 =
      expf(-((x - 1.92f) * (x - 1.92f) + (z + 1.65f) * (z + 1.65f)) / 0.16f);
  float puddle2 =
      expf(-((x + 1.91f) * (x + 1.91f) + (z - 1.38f) * (z - 1.38f)) / 0.15f);
  float patches = sat((noise(x * 1.8f + offset, z * 1.8f) - 0.53f) * 3.0f);
  field[i] = make_float4(
      h, water * (mask * patches + 3.4f * (puddle1 + puddle2)), x, z);
  mixture[i] =
      make_float4(h * (0.22f + 0.09f * noise(x * 1.3f + offset, z * 1.3f)),
                  0.0f, 0.0f, noise(x * 2.7f + offset, z * 2.7f));
  structure[i] = 1.0f;
  drive[i]=make_float4(0.0f,0.0f,0.0f,0.0f);
  residue[i] = make_float4(0.0f, 0.0f, 0.0f, 0.0f);
  material[i] = make_float4(0.0f, 0.0f, 0.0f, 0.0f);
  if (i < 4) {
    objects[i * 2] =
        make_float4(-1.15f + (float)i * 0.76f, 0.60f + (float)i * 0.09f,
                    0.28f * sinf((float)i * 3.0f),
                    i == 3 ? 0.32f : 0.24f + (float)i * 0.025f);
    objects[i * 2 + 1] = make_float4(0.0f, 0.0f, 0.0f, (float)i);
  }
}
// Object integration with gravity, wet soil support, velocity damping and
// sticky release.
__global__ void objects_step(const float4 *field, const float4 *input,
                             float4 *output, int n, float dt, int selected,
                             int held, float targetX, float targetZ,
                             float softness) {
  int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
  if (i >= 4)
    return;
  float4 p = input[i * 2];
  float4 v = input[i * 2 + 1];
  float4 f = sample(field, p.x, p.z, n);
  float rest = p.w + f.x * (0.70f - 0.25f * softness);
  if (i == selected && held == 1) {
    // A damped grab spring leaves resistance and release inertia in CUDA.
    float resistance = 7.0f + sat((rest + 0.05f - p.y) * 12.0f) * 8.0f;
    v.x = (v.x + (targetX - p.x) * dt * 320.0f) * expf(-dt * resistance);
    v.z = (v.z + (targetZ - p.z) * dt * 320.0f) * expf(-dt * resistance);
    float speed = sqrtf(v.x * v.x + v.z * v.z);
    float limit = fminf(1.0f, 4.5f / fmaxf(speed, 0.00001f));
    v.x *= limit;
    v.z *= limit;
    p.x += v.x * dt;
    p.z += v.z * dt;
  } else {
    float drag = expf(-dt * (p.y < rest + 0.03f ? 12.0f : 0.9f));
    v.x *= drag;
    v.z *= drag;
    p.x += v.x * dt;
    p.z += v.z * dt;
  }
  if (p.y > rest + .025f) {
    v.y -= 9.81f*dt;
    p.y = fmaxf(rest,p.y+v.y*dt);
    if (p.y<=rest) v.y=0.0f;
  } else {
    // Overdamped penetration, no stored spring energy or bounce on release.
    float oldY=p.y;
    p.y = p.y+(rest-p.y)*(1.0f-expf(-dt*18.0f));
    p.y = fmaxf(p.w,p.y);
    v.y = (p.y-oldY)/dt;
  }
  p.x = fminf(2.1f, fmaxf(-2.1f, p.x));
  p.z = fminf(2.1f, fmaxf(-2.1f, p.z));
  for (int j = 0; j < 4; j++) {
    if (j != i) {
      float4 q = input[j * 2];
      float dx = p.x - q.x;
      float dy = p.y - q.y;
      float dz = p.z - q.z;
      float len = sqrtf(dx * dx + dy * dy + dz * dz);
      float limit = p.w + q.w;
      if (len < limit && len > 0.00001f) {
        float overlap = (limit - len) * 0.52f;
        float inv = 1.0f / len;
        p.x += dx * inv * overlap;
        p.y += dy * inv * overlap;
        p.z += dz * inv * overlap;
        float speed = v.x * dx * inv + v.y * dy * inv + v.z * dz * inv;
        if (speed < 0.0f) {
          v.x -= speed * dx * inv;
          v.y -= speed * dy * inv;
          v.z -= speed * dz * inv;
        }
      }
    }
  }
  if (p.y < p.w) {
    p.y = p.w;
    v.y = fmaxf(0.0f, v.y);
  }
  output[i * 2] = p;
  output[i * 2 + 1] = v;
}
// Yield-limited creep preserves tracks. Conservative pressure transport creates
// an indentation and surrounding heave, while tangential contact transports
// UVs.
__global__ void mud_step(const float4 *input, float4 *output,
                         const float4 *objects, const float4 *flux, int n,
                         float dt, float softness, int brush, float bx,
                         float bz, float radius, float amount) {
  int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
  if (i >= n * n)
    return;
  int ix = i % n;
  int iz = i / n;
  float x = (float)ix * 5.0f / (float)(n - 1) - 2.5f;
  float z = (float)iz * 5.0f / (float)(n - 1) - 2.5f;
  float4 f = input[i];
  float4 flow = flux[i];
  f.x -= flow.x + flow.y + flow.z + flow.w;
  if (ix > 0)
    f.x += flux[i - 1].y;
  if (ix < n - 1)
    f.x += flux[i + 1].x;
  if (iz > 0)
    f.x += flux[i - n].w;
  if (iz < n - 1)
    f.x += flux[i + n].z;
  float remaining = fmaxf(0.0f, input[i].x - flow.x - flow.y - flow.z - flow.w);
  float u = input[i].z * remaining;
  float v = input[i].w * remaining;
  if (ix > 0) {
    float q = flux[i - 1].y;
    u += input[i - 1].z * q;
    v += input[i - 1].w * q;
  }
  if (ix < n - 1) {
    float q = flux[i + 1].x;
    u += input[i + 1].z * q;
    v += input[i + 1].w * q;
  }
  if (iz > 0) {
    float q = flux[i - n].w;
    u += input[i - n].z * q;
    v += input[i - n].w * q;
  }
  if (iz < n - 1) {
    float q = flux[i + n].z;
    u += input[i + n].z * q;
    v += input[i + n].w * q;
  }
  if (f.x > 0.00001f) {
    f.z = u / f.x;
    f.w = v / f.x;
  }
  float d = sqrtf((x - bx) * (x - bx) + (z - bz) * (z - bz));
  float weight = expf(-d * d / (radius * radius) * 3.0f);
  if (brush == 1)
    f.y = fminf(0.20f, f.y + weight * amount * dt * 0.045f);
  if (brush == 2)
    f.x = fmaxf(0.0f, f.x - weight * amount * dt * 0.12f);
  if (brush == 3)
    f.x = fminf(0.55f, f.x + weight * amount * dt * 0.12f);

  output[i] = f;
}
__global__ void water_flux(const float4 *field, const float4 *mixture,
                           const float4 *objects, float4 *flux, int n,
                           float dt) {
  int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
  if (i >= n * n)
    return;
  int x = i % n;
  int z = i / n;
  float4 p = field[i];
  float spacing = 5.0f / (float)(n - 1);
  float px = (float)x * spacing - 2.5f;
  float pz = (float)z * spacing - 2.5f;
  float h =
      p.x + p.y + mixture[i].y + pressure(field, objects, px, pz, n) * 0.28f;
  float a = 0.0f;
  float b = 0.0f;
  float c = 0.0f;
  float d = 0.0f;
  float rate = dt * 18.0f;
  if (x > 0) {
    float4 q = field[i - 1];
    a = fmaxf(0.0f, h - q.x - q.y - mixture[i - 1].y -
                        pressure(field, objects, px - spacing, pz, n) * 0.28f) *
        rate;
  }
  if (x < n - 1) {
    float4 q = field[i + 1];
    b = fmaxf(0.0f, h - q.x - q.y - mixture[i + 1].y -
                        pressure(field, objects, px + spacing, pz, n) * 0.28f) *
        rate;
  }
  if (z > 0) {
    float4 q = field[i - n];
    c = fmaxf(0.0f, h - q.x - q.y - mixture[i - n].y -
                        pressure(field, objects, px, pz - spacing, n) * 0.28f) *
        rate;
  }
  if (z < n - 1) {
    float4 q = field[i + n];
    d = fmaxf(0.0f, h - q.x - q.y - mixture[i + n].y -
                        pressure(field, objects, px, pz + spacing, n) * 0.28f) *
        rate;
  }
  float scale = fminf(1.0f, p.y / fmaxf(a + b + c + d, 0.0000001f));
  flux[i] = make_float4(a, b, c, d) * scale;
}
__global__ void water_step(const float4 *input, const float4 *flux,
                           float4 *output, int n) {
  int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
  if (i >= n * n)
    return;
  int x = i % n;
  int z = i / n;
  float4 p = input[i];
  float4 f = flux[i];
  float w = p.y - f.x - f.y - f.z - f.w;
  if (x > 0)
    w += flux[i - 1].y;
  if (x < n - 1)
    w += flux[i + 1].x;
  if (z > 0)
    w += flux[i - n].w;
  if (z < n - 1)
    w += flux[i + n].z;
  p.y = fmaxf(0.0f, w);
  output[i] = p;
}
// Painted clay and edited normals travel with the same conserved solid flux.
__global__ void material_transport(const float4 *field, const float4 *flux,
                                   const float4 *input, float4 *output, int n) {
  int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
  if (i >= n * n)
    return;
  int x = i % n;
  int z = i / n;
  float4 f = flux[i];
  float left = fmaxf(0.0f, field[i].x - f.x - f.y - f.z - f.w);
  float mass = left;
  float4 value = input[i] * left;
  if (x > 0) {
    float q = flux[i - 1].y;
    mass += q;
    value += input[i - 1] * q;
  }
  if (x < n - 1) {
    float q = flux[i + 1].x;
    mass += q;
    value += input[i + 1] * q;
  }
  if (z > 0) {
    float q = flux[i - n].w;
    mass += q;
    value += input[i - n] * q;
  }
  if (z < n - 1) {
    float q = flux[i + n].z;
    mass += q;
    value += input[i + n] * q;
  }
  output[i] = mass > 0.00001f ? value / mass : input[i];
}
// Mixture float4: absorbed pore water (m), suspended solid (m), cumulative
// kneading [0,1], clay pigment fraction. Residue stays attached to concrete:
// solid thickness (m), wetness memory, pigment fraction, smear strength.
__global__ void mixture_solid(const float4 *field, const float4 *flux,
                              const float4 *input, float4 *output, const float *structure, float *outputStructure, int n) {
  int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
  if (i >= n * n)
    return;
  int x = i % n;
  int z = i / n;
  float4 f = flux[i];
  float outgoing = f.x + f.y + f.z + f.w;
  float retained = fmaxf(0.0f, field[i].x - outgoing);
  float4 old = input[i];
  float bound =
      old.x * (1.0f - fminf(1.0f, outgoing / fmaxf(field[i].x, 0.0000001f)));
  float pigment = old.w * retained;
  float knead = old.z * retained;
  float mass = retained;
  float strength = structure[i]*retained;
  if (x > 0) {
    float q = flux[i - 1].y;
    mass += q;
    bound += input[i - 1].x * q / fmaxf(field[i - 1].x, 0.0000001f);
    pigment += input[i - 1].w * q;
    strength += structure[i - 1] * q;
    knead += input[i - 1].z * q;
  }
  if (x < n - 1) {
    float q = flux[i + 1].x;
    mass += q;
    bound += input[i + 1].x * q / fmaxf(field[i + 1].x, 0.0000001f);
    pigment += input[i + 1].w * q;
    strength += structure[i + 1] * q;
    knead += input[i + 1].z * q;
  }
  if (z > 0) {
    float q = flux[i - n].w;
    mass += q;
    bound += input[i - n].x * q / fmaxf(field[i - n].x, 0.0000001f);
    pigment += input[i - n].w * q;
    strength += structure[i - n] * q;
    knead += input[i - n].z * q;
  }
  if (z < n - 1) {
    float q = flux[i + n].z;
    mass += q;
    bound += input[i + n].x * q / fmaxf(field[i + n].x, 0.0000001f);
    pigment += input[i + n].w * q;
    strength += structure[i + n] * q;
    knead += input[i + n].z * q;
  }
  outputStructure[i] = mass > .000001f ? sat(strength/mass) : 1.0f;
  output[i] = make_float4(bound, old.y, mass > 0.00001f ? knead / mass : old.z,
                          mass > 0.00001f ? pigment / mass : old.w);
}
__global__ void mixture_water(const float4 *field, const float4 *flux,
                              const float4 *input, float4 *output, int n) {
  int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
  if (i >= n * n)
    return;
  int x = i % n;
  int z = i / n;
  float4 f = flux[i];
  float4 m = input[i];
  float out = f.x + f.y + f.z + f.w;
  float sediment =
      m.y * (1.0f - fminf(1.0f, out / fmaxf(field[i].y, 0.0000001f)));
  if (x > 0)
    sediment +=
        input[i - 1].y * flux[i - 1].y / fmaxf(field[i - 1].y, 0.0000001f);
  if (x < n - 1)
    sediment +=
        input[i + 1].y * flux[i + 1].x / fmaxf(field[i + 1].y, 0.0000001f);
  if (z > 0)
    sediment +=
        input[i - n].y * flux[i - n].w / fmaxf(field[i - n].y, 0.0000001f);
  if (z < n - 1)
    sediment +=
        input[i + n].y * flux[i + n].z / fmaxf(field[i + n].y, 0.0000001f);
  m.y = fmaxf(0.0f, sediment);
  output[i] = m;
}
// Local reactions conserve water and solid across free/absorbed/suspended/stuck
// compartments. Churning accelerates hydration and picks clay into the water.
__global__ void churn(float4 *field, float4 *mixture, float4 *residue, float *structure, float4 *drive,
                      const float4 *objects, const float4 *solidFlux, int n,
                      float dt, int brush, float bx, float bz, float radius,
                      float brushVX, float brushVZ, float amount) {
  int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
  if (i >= n * n)
    return;
  float x = (float)(i % n) * 5.0f / (float)(n - 1) - 2.5f;
  float z = (float)(i / n) * 5.0f / (float)(n - 1) - 2.5f;
  float activity = 0.0f;
  for (int j = 0; j < 4; j++) {
    float4 p = objects[j * 2];
    float4 vel = objects[j * 2 + 1];
    float dx = x - p.x;
    float dz = z - p.z;
    float q = (dx * dx + dz * dz) / (p.w * p.w);
    float touch = sat((field[i].x + p.w - p.y) / fmaxf(.015f, p.w * .45f));
    activity += sqrtf(vel.x * vel.x + vel.z * vel.z) * expf(-q * 1.7f) * touch;
  }
  if (brush == 8) {
    float w = expf(-((x - bx) * (x - bx) + (z - bz) * (z - bz)) /
                   (radius * radius) * 3.0f);
    activity += sqrtf(brushVX * brushVX + brushVZ * brushVZ) * w * amount;
  }
  float4 f = field[i];
  float4 m = mixture[i];
  float4 r = residue[i];
  float capacity = f.x * 0.35f;
  float exchange =
      fminf(f.y, fmaxf(0.0f, capacity - m.x) * dt *
                     (0.015f + activity * 14.0f) * sat(f.y * 500.0f));
  f.y -= exchange;
  m.x += exchange;
  float excess = fmaxf(0.0f, m.x - capacity);
  float release = fminf(m.x, excess * dt * 12.0f);
  m.x -= release;
  f.y += release;
  float erosion =
      fminf(f.x, f.y * dt * (0.002f + activity * 0.55f) * sat(f.x * 300.0f));
  float boundReleased = m.x * erosion / fmaxf(f.x, 0.0000001f);
  m.x -= boundReleased;
  f.y += boundReleased;
  f.x -= erosion;
  m.y += erosion;
  float settled = fminf(m.y, m.y * dt * 0.22f / (1.0f + activity * 12.0f));
  m.y -= settled;
  float deposit = settled * sat((0.004f - f.x) * 250.0f);
  f.x += settled - deposit;
  float4 flow = solidFlux[i];
  float moving = flow.x + flow.y + flow.z + flow.w;
  float coating = fminf(f.x, fminf(fmaxf(0.0f, 0.0015f - r.x),
                                   moving * 0.0015f + activity * dt * 0.00003f *
                                                          sat(f.x * 300.0f)));
  boundReleased = m.x * coating / fmaxf(f.x, 0.0000001f);
  m.x -= boundReleased;
  f.y += boundReleased;
  f.x -= coating;
  deposit += coating;
  if (deposit > 0.0f) {
    r.z = (r.z * r.x + m.w * deposit) / fmaxf(r.x + deposit, 0.0000001f);
    r.x += deposit;
  }
  r.y = fmaxf(r.y * expf(-dt * 0.025f), sat((f.y + m.x) * 180.0f));
  r.w = fmaxf(r.w * expf(-dt * 0.004f), sat(activity * 0.5f));
  m.z = sat(m.z + activity * dt * 0.8f * sat((m.x + f.y) * 300.0f));
  // Reversible structure recovery is distinct from permanent pigment mixing.
  float lambda = structure[i];
  float strainRate = activity/fmaxf(.025f,f.x);
  structure[i] = sat((lambda+dt*.125f)/(1.0f+dt*(.125f+.65f*strainRate)));
  // Gather signed face fluxes into the fine material's integrated displacement.
  int ix=i%n,iz=i/n;
  float qx=flow.y-flow.x,qz=flow.w-flow.z;
  if(ix>0) qx+=solidFlux[i-1].y;
  if(ix<n-1) qx-=solidFlux[i+1].x;
  if(iz>0) qz+=solidFlux[i-n].w;
  if(iz<n-1) qz-=solidFlux[i+n].z;
  float spacing=5.0f/(float)(n-1);
  float scale=spacing/(2.0f*fmaxf(f.x,.001f));
  float4 movement=drive[i];
  movement.x+=fminf(dt*6.0f,fmaxf(-dt*6.0f,qx*scale));
  movement.y+=fminf(dt*6.0f,fmaxf(-dt*6.0f,qz*scale));
  movement.z+=strainRate*dt;
  movement.w+=activity*dt;
  drive[i]=movement;
  field[i] = f;
  mixture[i] = m;
  residue[i] = r;
}
// Persistent material paint and tangent-normal edits, independent of geometry.
__global__ void material_edit(float4 *material, float4 *field, int n, float dt, int brush,
                              float bx, float bz, float radius, float amount,
                              float brushVX, float brushVZ) {
  int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
  if (i >= n * n)
    return;
  float x = (float)(i % n) * 5.0f / (float)(n - 1) - 2.5f;
  float z = (float)(i / n) * 5.0f / (float)(n - 1) - 2.5f;
  float dx = x - bx;
  float dz = z - bz;
  float weight = expf(-(dx * dx + dz * dz) / (radius * radius) * 3.0f);
  float4 f = material[i];
  if (brush == 4) {
    float4 uv = field[i];
    uv.z -= brushVX * weight * dt * amount * .85f;
    uv.w -= brushVZ * weight * dt * amount * .85f;
    field[i] = uv;
  }
  if (brush == 5) {
    f.x = sat(f.x + weight * dt * amount);
    f.y = fmaxf(-0.3f, f.y - weight * dt * amount * 0.25f);
  }
  if (brush == 6) {
    f.z = fminf(0.8f,
                fmaxf(-0.8f, f.z + dx / radius * weight * dt * amount * 3.0f));
    f.w = fminf(0.8f,
                fmaxf(-0.8f, f.w + dz / radius * weight * dt * amount * 3.0f));
  }
  if (brush == 7)
    f *= 1.0f - sat(weight * dt * amount * 5.0f);
  material[i] = f;
}
__device__ float3 sky(float3 d) {
  float t = sat(d.y * 0.8f + 0.4f);
  // Broad overhead light panels provide readable reflections across wet folds.
  float panel = expf(-((d.x + .35f) * (d.x + .35f) * 18.0f +
                       (d.z + .60f) * (d.z + .60f) * 5.0f)) * sat(d.y * 3.0f);
  return make_float3(0.20f + t * .35f + panel * 5.0f,
                     0.23f + t * .38f + panel * 4.7f,
                     0.25f + t * .42f + panel * 4.2f);
}
__global__ void render(const float4 *field, const float4 *materialMap,
                       const float4 *objects, const unsigned int *textureMap,
                       const float4 *mixture, const float4 *residue,
                       const float4 *colours, const float4 *coordinates, const float4 *swipes,
                       unsigned int *pixels, int textureSize, int chainLength, int detailN, int n, int width,
                       int rows, float yaw, float pitch, float distance,
                       float textureScale, float bump, float wetness, int view,
                       int selected, float time) {
  int i = (int)(blockIdx.x * blockDim.x + threadIdx.x);
  if (i >= width * rows)
    return;
  float sx = ((float)(i % width) + 0.5f - (float)width * 0.5f) / (float)rows;
  float sy = ((float)rows * 0.5f - (float)(i / width) - 0.5f) / (float)rows;
  float cy = cosf(yaw);
  float syaw = sinf(yaw);
  float cp = cosf(pitch);
  float sp = sinf(pitch);
  float3 ro =
      make_float3(syaw * cp * distance, sp * distance, cy * cp * distance);
  float3 right = make_float3(cy, 0.0f, -syaw);
  float3 up = make_float3(-syaw * sp, cp, -cy * sp);
  float3 forward = norm(mul(ro, -1.0f));
  float3 rd =
      norm(add(forward, add(mul(right, sx * 1.25f), mul(up, sy * 1.25f))));
  float3 col = make_float3(0.012f, 0.018f, 0.015f);
  float t = 100.0f;
  float3 normal = make_float3(0.0f, 1.0f, 0.0f);
  int material = -1;
  int diagnostic = 0;
  int side = 0;
  float3 hit = ro;
  // Bracket first heightfield intersection using bounded marching through the
  // slab.
  float enter = 0.0f;
  float exit = 100.0f;
  float dx = rd.x;
  if (fabsf(dx) < 0.00001f)
    dx = 0.00001f;
  float dz = rd.z;
  if (fabsf(dz) < 0.00001f)
    dz = 0.00001f;
  float tx0 = (-2.5f - ro.x) / dx;
  float tx1 = (2.5f - ro.x) / dx;
  float tz0 = (-2.5f - ro.z) / dz;
  float tz1 = (2.5f - ro.z) / dz;
  enter = fmaxf(enter, fmaxf(fminf(tx0, tx1), fminf(tz0, tz1)));
  exit = fminf(exit, fminf(fmaxf(tx0, tx1), fmaxf(tz0, tz1)));
  float top = (1.2f - ro.y) / rd.y;
  float bottom = (0.0f - ro.y) / rd.y;
  enter = fmaxf(enter, fminf(top, bottom));
  exit = fminf(exit, fmaxf(top, bottom));
  if (exit > enter) {
    float prev = enter;
    for (int k = 0; k < 48; k++) {
      float tt = enter + (exit - enter) * (float)k / 47.0f;
      float3 p = add(ro, mul(rd, tt));
      if (p.y <= height(field, mixture, p.x, p.z, n)) {
        float lo = prev;
        float hi = tt;
        for (int q = 0; q < 6; q++) {
          float mid = (lo + hi) * 0.5f;
          float3 m = add(ro, mul(rd, mid));
          if (m.y > height(field, mixture, m.x, m.z, n))
            lo = mid;
          else
            hi = mid;
        }
        t = hi;
        material = 0;
        if (k == 0) {
          side = 1;
          if (fminf(tx0, tx1) > fminf(tz0, tz1))
            normal = make_float3(rd.x > 0.0f ? -1.0f : 1.0f, 0.0f, 0.0f);
          else
            normal = make_float3(0.0f, 0.0f, rd.z > 0.0f ? -1.0f : 1.0f);
        }
        break;
      }
      prev = tt;
    }
  }
  float3 inv = make_float3(1.0f / rd.x, 1.0f / rd.y, 1.0f / rd.z);
  float ax0 = (-2.5f - ro.x) * inv.x;
  float ax1 = (2.5f - ro.x) * inv.x;
  float ay0 = (-0.22f - ro.y) * inv.y;
  float ay1 = (0.0f - ro.y) * inv.y;
  float az0 = (-2.5f - ro.z) * inv.z;
  float az1 = (2.5f - ro.z) * inv.z;
  float ax = fminf(ax0, ax1);
  float ay = fminf(ay0, ay1);
  float az = fminf(az0, az1);
  float near = fmaxf(ax, fmaxf(ay, az));
  float far = fminf(fmaxf(ax0, ax1), fminf(fmaxf(ay0, ay1), fmaxf(az0, az1)));
  if (far >= near && near > 0.0f && near < t) {
    t = near;
    material = 5;
    normal = make_float3(0.0f, 0.0f, 0.0f);
    if (near == ax)
      normal.x = rd.x > 0.0f ? -1.0f : 1.0f;
    else if (near == ay)
      normal.y = rd.y > 0.0f ? -1.0f : 1.0f;
    else
      normal.z = rd.z > 0.0f ? -1.0f : 1.0f;
  }
  for (int j = 0; j < 4; j++) {
    float4 o = objects[j * 2];
    float3 oc = add(ro, make_float3(-o.x, -o.y, -o.z));
    float b = dot3(oc, rd);
    float c = dot3(oc, oc) - o.w * o.w;
    float disc = b * b - c;
    float tt = 100.0f;
    float3 nn = normal;
    if (j < 3 && disc > 0.0f) {
      tt = -b - sqrtf(disc);
      nn = norm(add(add(ro, mul(rd, tt)), make_float3(-o.x, -o.y, -o.z)));
    }
    if (j == 3) {
      float3 inv = make_float3(1.0f / rd.x, 1.0f / rd.y, 1.0f / rd.z);
      float3 a = make_float3((-o.w - oc.x) * inv.x, (-o.w - oc.y) * inv.y,
                             (-o.w - oc.z) * inv.z);
      float3 b3 = make_float3((o.w - oc.x) * inv.x, (o.w - oc.y) * inv.y,
                              (o.w - oc.z) * inv.z);
      float ax = fminf(a.x, b3.x);
      float ay = fminf(a.y, b3.y);
      float az = fminf(a.z, b3.z);
      float lo = fmaxf(ax, fmaxf(ay, az));
      float hi =
          fminf(fmaxf(a.x, b3.x), fminf(fmaxf(a.y, b3.y), fmaxf(a.z, b3.z)));
      if (hi > lo) {
        tt = lo;
        nn = make_float3(0.0f, 0.0f, 0.0f);
        if (lo == ax)
          nn.x = rd.x > 0.0f ? -1.0f : 1.0f;
        else if (lo == ay)
          nn.y = rd.y > 0.0f ? -1.0f : 1.0f;
        else
          nn.z = rd.z > 0.0f ? -1.0f : 1.0f;
      }
    }
    if (tt > 0.0f && tt < t) {
      t = tt;
      material = j + 1;
      normal = nn;
    }
  }
  if (material >= 0) {
    hit = add(ro, mul(rd, t));
    float3 base = make_float3(0.072f, 0.033f, 0.016f);
    float wet = 0.0f;
    float rough = 0.7f;
    if (material == 0) {
      diagnostic = view > 0 ? 1 : 0;
      float4 f = sample(field, hit.x, hit.z, n);
      float4 paint = sample(materialMap, hit.x, hit.z, n);
      float4 mix = sample(mixture, hit.x, hit.z, n);
      float4 stain = sample(residue, hit.x, hit.z, n);
      float moisture = sat(mix.x / fmaxf(f.x * 0.35f, 0.00001f));
      float pool = sat((f.y - 0.0006f) * 350.0f);
      float turbidity = sat(mix.y / fmaxf(f.y, 0.000001f) * 14.0f);
      float e = 5.0f / (float)(n - 1);
      float nx = (height(field, mixture, hit.x - e, hit.z, n) -
                  height(field, mixture, hit.x + e, hit.z, n)) /
                 (2.0f * e);
      float nz = (height(field, mixture, hit.x, hit.z - e, n) -
                  height(field, mixture, hit.x, hit.z + e, n)) /
                 (2.0f * e);
      wet = sat((moisture * 0.65f + pool) * (.55f + wetness * .45f));
      float4 coord=sample(coordinates,hit.x,hit.z,detailN);
      float4 weights=sample(colours,hit.x,hit.z,detailN);
      float4 swipe=sample(swipes,hit.x,hit.z,detailN);
      float u=coord.x*textureScale,v=coord.y*textureScale;
      float footprint=t*1.25f/(float)rows/fmaxf(.3f,fabsf(rd.y))*textureScale;
      int level=0;float texel=5.0f/(float)textureSize;
      for(int k=0;k<12;k++) {if(texel<footprint*.75f){texel*=2.0f;level++;}}
      float4 tex=layeredAtlas(textureMap,u,v,textureSize,chainLength,level,weights,swipe);
      float detail = tex.x * (1.0f - mix.z * .45f) + mix.z * .45f;
      float4 uvL = sample(coordinates, hit.x-e, hit.z, detailN);
      float4 uvR = sample(coordinates, hit.x+e, hit.z, detailN);
      float4 uvD = sample(coordinates, hit.x, hit.z-e, detailN);
      float4 uvU = sample(coordinates, hit.x, hit.z+e, detailN);
      float duDx = fminf(4.0f,fmaxf(-4.0f,(uvR.x-uvL.x)/(2.0f*e))) * textureScale;
      float dvDx = fminf(4.0f,fmaxf(-4.0f,(uvR.y-uvL.y)/(2.0f*e))) * textureScale;
      float duDz = fminf(4.0f,fmaxf(-4.0f,(uvU.x-uvD.x)/(2.0f*e))) * textureScale;
      float dvDz = fminf(4.0f,fmaxf(-4.0f,(uvU.y-uvD.y)/(2.0f*e))) * textureScale;
      float gradU = (layeredAtlas(textureMap,u-texel,v,textureSize,chainLength,level,weights,swipe).y -
                     layeredAtlas(textureMap,u+texel,v,textureSize,chainLength,level,weights,swipe).y)/(2.0f*texel);
      float gradV = (layeredAtlas(textureMap,u,v-texel,textureSize,chainLength,level,weights,swipe).y -
                     layeredAtlas(textureMap,u,v+texel,textureSize,chainLength,level,weights,swipe).y)/(2.0f*texel);
      float detailStrength = bump*(1.0f-pool*.96f*(1.0f-turbidity*.65f))*(1.0f-mix.z*.30f);
      nx += (gradU*duDx + gradV*dvDx)*detailStrength;
      nz += (gradU*duDz + gradV*dvDz)*detailStrength;
      // Shallow water micro-ripples respond to moving contact bodies.
      for (int j = 0; j < 4; j++) {
        float4 body = objects[j * 2];
        float4 vel = objects[j * 2 + 1];
        float dx = hit.x - body.x;
        float dz = hit.z - body.z;
        float radius = sqrtf(dx * dx + dz * dz);
        float speed = fminf(1.8f, sqrtf(vel.x * vel.x + vel.z * vel.z));
        float wave = cosf(radius * 45.0f - time * 15.0f) *
                     expf(-radius * 2.8f) * speed * 0.10f * sat(f.y * 70.0f);
        nx += wave * dx / fmaxf(radius, 0.01f);
        nz += wave * dz / fmaxf(radius, 0.01f);
      }
      if (side == 0)
        normal = norm(make_float3(nx + coord.z, 1.0f, nz + coord.w));
      else
        wet = 0.0f;
      float3 clay=add(add(mul(make_float3(.035f,.014f,.007f),weights.x),
                             mul(make_float3(.105f,.048f,.020f),weights.y)),
                         mul(make_float3(.120f,.090f,.055f),weights.z));
      base = mul(clay,
                 detail * (1.0f - paint.x * .08f) * (1.0f - moisture * .32f));
      rough = fmaxf(.065f, (tex.z + .16f) * (1.0f - moisture * .78f) *
                                   (1.0f - mix.z * .25f) +
                               paint.y);
      float cover = sat(f.x / .003f);
      float dirty = 1.0f - expf(-stain.x * 4500.0f);
      float3 concrete = mul(make_float3(.19f, .20f, .18f),
                            .8f + noise(hit.x * 140.0f, hit.z * 140.0f) * .25f);
      float3 film = mul(clay, .75f + noise(hit.x * 47.0f, hit.z * 47.0f) * .3f);
      concrete = add(mul(concrete, 1.0f - dirty), mul(film, dirty));
      base = add(mul(base, cover), mul(concrete, 1.0f - cover));
      if (cover < .01f && pool < .01f) {
        if (side == 0)
          normal = make_float3(0.0f, 1.0f, 0.0f);
        rough = .85f - dirty * .45f;
        wet = dirty * stain.y * .45f;
        if (dirty < .01f)
          material = 5;
      }
      float transmission = expf(-f.y * (8.0f + turbidity * 170.0f));
      float3 waterColour =
          add(mul(make_float3(.012f, .040f, .047f), 1.0f - turbidity),
              mul(clay, turbidity * .75f));
      base = add(mul(base, 1.0f - pool * (1.0f - transmission)),
                 mul(waterColour, pool * (1.0f - transmission)));
      rough = rough * (1.0f - pool) + (.04f + turbidity * .08f) * pool;
      if(view==6) {base=make_float3(weights.x,weights.y,weights.z);wet=0.0f;}
      if(view==7) {base=make_float3(swipe.x*.5f+.5f,swipe.y*.5f+.5f,swipe.z);wet=0.0f;}
      if (view == 4) {
        base = make_float3(moisture, pool, turbidity);
        wet = 0.0f;
      }
      if (view == 5) {
        base = make_float3(dirty, stain.w, mix.z);
        wet = 0.0f;
      }
      if (view == 1) {
        base = make_float3(sat(0.5f + f.x * 3.0f), sat(f.y * 18.0f), 0.22f);
        wet = 0.0f;
      }
      if (view == 2) {
        base = make_float3(normal.x * 0.5f + 0.5f, normal.y * 0.5f + 0.5f,
                           normal.z * 0.5f + 0.5f);
        wet = 0.0f;
      }
      if (view == 3) {
        base = make_float3(
            0.15f + 0.7f * sat(sinf(u * 8.0f) * sinf(v * 8.0f) * 5.0f), 0.25f,
            0.12f);
        wet = 0.0f;
      }
    } else if (material == 5) {
      float pores =
          noise(hit.x * 130.0f + hit.y * 47.0f, hit.z * 130.0f + hit.y * 77.0f);
      float flecks = noise(hit.x * 420.0f + hit.y * 193.0f,
                           hit.z * 420.0f + hit.y * 53.0f);
      base = mul(make_float3(0.21f, 0.22f, 0.20f),
                 0.7f + pores * 0.30f + flecks * 0.15f);
      float4 stain = sample(residue, hit.x, hit.z, n);
      float dirty = 1.0f - expf(-stain.x * 4500.0f);
      if (hit.y > -.002f) {
        base = add(mul(base, 1.0f - dirty),
                   mul(make_float3(.036f, .021f, .011f), dirty));
        wet = dirty * stain.y * .4f;
      }
      rough = .9f - dirty * .45f;
    } else {
      if (material == 1)
        base = make_float3(0.52f, 0.21f, 0.055f);
      if (material == 2)
        base = make_float3(0.08f, 0.24f, 0.25f);
      if (material == 3)
        base = make_float3(0.48f, 0.44f, 0.32f);
      if (material == 4)
        base = make_float3(0.25f, 0.29f, 0.32f);
      float4 o = objects[(material - 1) * 2];
      float coating =
          sat((sample(field, hit.x, hit.z, n).x + 0.06f - hit.y) * 20.0f);
      base = add(mul(base, 1.0f - coating),
                 mul(make_float3(0.085f, 0.043f, 0.022f), coating));
      rough = 0.18f + coating * 0.23f;
      wet = 0.35f;
      if (material - 1 == selected)
        base = mul(base, 1.15f);
    }
    float3 light = norm(make_float3(-0.6f, 1.0f, 0.4f));
    float diffuse = fmaxf(0.0f, dot3(normal, light));
    float shadow = 1.0f;
    for (int j = 0; j < 4; j++) {
      float4 o = objects[j * 2];
      float3 delta = make_float3(o.x - hit.x, o.y - hit.y, o.z - hit.z);
      float along = dot3(delta, light);
      float perp = fmaxf(0.0f, dot3(delta, delta) - along * along);
      if (along > 0.02f)
        shadow *= 1.0f - 0.65f * expf(-perp / (o.w * o.w * 1.2f));
    }
    float3 halfv = norm(add(light, mul(rd, -1.0f)));
    float spec =
        powf(fmaxf(0.0f, dot3(normal, halfv)), 2.0f / (rough * rough)) *
        ((material == 5   ? 0.015f
          : material == 0 ? 0.12f
                          : 0.45f) +
         wet * 0.7f) *
        shadow;
    float fres =
        0.025f +
        0.65f * powf(1.0f - fmaxf(0.0f, dot3(normal, mul(rd, -1.0f))), 5.0f);
    float3 reflected = add(rd, mul(normal, -2.0f * dot3(rd, normal)));
    col = add(mul(base, 0.40f + diffuse * shadow * 1.9f),
              add(mul(sky(reflected), wet * fres),
                  make_float3(spec, spec * 0.92f, spec * 0.8f)));
    if (diagnostic == 1) col = base;
  } else {
    float tt = (-0.23f - ro.y) / rd.y;
    if (tt > 0.0f) {
      float3 p = add(ro, mul(rd, tt));
      float shade = expf(-(p.x * p.x + p.z * p.z) * 0.065f);
      col = make_float3(0.011f + shade * 0.006f, 0.016f + shade * 0.007f,
                        0.013f + shade * 0.006f);
    }
  }
  if (diagnostic == 0)
    col = make_float3(powf(sat(col.x), 0.4545f), powf(sat(col.y), 0.4545f),
                    powf(sat(col.z), 0.4545f));
  pixels[i] = (unsigned int)(col.x * 255.0f) |
              ((unsigned int)(col.y * 255.0f) << 8) |
              ((unsigned int)(col.z * 255.0f) << 16) | 4278190080u;
}
