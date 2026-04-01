#include "PlanetClouds.cginc"
#include "Assets/Graphics/Shader/DistortTools.cginc"
#include "Assets/Graphics/Shader/ShaderTools.cginc"
#include "Assets/Graphics/World/New Terrain/PlanetAtmosphere.cginc"

struct OceanNodeData
{
    int transformId;

    // Dimensions
    float3 position;
    float radius;
    int level;
    int planetId;
    float size;

    float3 uAxis;
    float3 vAxis;

    // Tree ids
    int ultimateParentId;
    int parentId;
    int4 childrens;

    int fadeState;
    float fadeTime;
    float fadeTarget;
    float3 boundsCenter;
    float3 boundsSize;
    int renderId;
    int inAudioRange;
    int padding;
    int2 eventInstance; // event instance is a 64bit pointer
};

StructuredBuffer<OceanNodeData> _OceanNodeDatasBuffer;
uniform float _WaterDensity;

float _BaseAlpha;
//float4 _WaterColor1;
//float4 _WaterColor2;
//float4 _DepthColor;

sampler2D _DistortionTexture;
sampler2D _WaterWaveNormalTex;
sampler2D _CausticTex;
sampler2D _WaveStrengthTexture;

float _WavesAmplitude;
float _MainFoamIntensity;
float3 _WaveDir1;
float3 _WaveDir2;
float _NormalStrength;
float4 _WaterExtinctionCoeff;
float4 _WaterInScatteringCoeff;
float _WaterRoughness;
float _WaterRoughnessFar;

float _WaveIterations;
float _WaveLacunarity;
float _WavePersistence;


#define CELL_COUNT 10

#define CAUSTIC_PAN1 float3(0.02, -0.01, -0.013)
#define CAUSTIC_PAN2 float3(-0.015, 0.025, -0.021)
#define CAUSTIC_SCALE 0.0625
#define CAUSTIC_DEPTH 30
//#define CAUSTIC_STRENGTH 0.6
#define CAUSTIC_STRENGTH 1

//#define GET_RADIUS(i) i.data.x
#define GET_PLANET_ID_WATER(i) i.data.x
//#define GET_NOISE(i) i.crossfadeFactor.w

// Noise params
#define SEA_HEIGHT 8.0
#define SEA_FREQ 0.05
#define STEP_WAVE 20
#define TIME_FACTOR 1.5
#define MESH_SIZE 25

struct v2f_planetOcean
{
    float4 pos : SV_POSITION;
    float3 wpos: TEXCOORD0;
    float3 color : TEXCOORD1;
    float3 crossfadeFactor : TEXCOORD2;
    float3 opos : TEXCOORD3;
    int4 data : TEXCOORD4;
    //float height: TEXCOORD5;
    
    #ifdef SHOW_WIREFRAME
        float2 faceUV : TEXCOORD6;
    #endif

    #ifdef SHOW_TESSELATION
    float3 vertexWeight : TEXCOORD7;
    #endif
};

struct v2f_planetOceanFog
{
    float4 pos : SV_POSITION;
    float3 wpos : TEXCOORD0;
};

/*static float2 VERTEX_POS[6] = {
    float2(0,0), float2(0,1), float2(1,1),
    float2(1,1), float2(1,0), float2(0,0)};*/

static float2 VERTEX_POS[4] = {
    float2(0,0), float2(0,1), float2(1,1), float2(1,0)};

// https://www.shadertoy.com/view/Ms2SD1

float2 wavedx(float3 position, float3 direction, float speed, float frequency, float timeshift) {
    float x = dot(direction, position) * frequency + timeshift * speed;
    float wave = exp(sin(x) - 1.0);
    float dx = wave * cos(x);
    return float2(wave, -dx);
}

float getwaves(float3 position)
{
    //float iter = 0.0;
    float iter = 1.0;

    float phase = 6.0;
    float speed = 2.0;
    float weight = 1.0;
    float w = 0.0;
    float ws = 0.0;
    position *= SEA_FREQ;

    // This is a big black box
    for(int i=0;i< STEP_WAVE; i++){
        float3 dir = float3(sin(iter), cos(iter), -cos(1.2 * iter + 1));
        float2 res = wavedx(position, dir, speed, phase, TIME_FACTOR * 0.45 * _Time.y);
        position += dir * res.y * weight * 0.048;
        w += res.x * weight;
        iter += 12.0;
        ws += weight;
        weight = lerp(weight, 0.0, 0.2);
        phase *= 1.18;
        speed *= 1.07;
    }
    return SEA_HEIGHT * (w / ws - 0.5);
}

float3 sea_heightVertex(float3 p)
{
    float3 rad = normalize(p);
    float strength = SampleTexTriplanarLod(rad, 0.002 * p + TIME_FACTOR * 0.1 * CAUSTIC_PAN1 * _Time.y, _WaveStrengthTexture, 0).r;
    return p + strength * getwaves(p) * rad;
}

float3 sea_height(float3 p, float3 rad)
{
    float strength = SampleTexTriplanarLod(rad, 0.002 * p + TIME_FACTOR * 0.1 * CAUSTIC_PAN1 * _Time.y, _WaveStrengthTexture, 0).r;
    return strength * getwaves(p);
}

float3 sea_height(float3 p, float radius)
{
    float3 rad = normalize(p);
    float strength = SampleTexTriplanar(rad, 0.002 * p + TIME_FACTOR * 0.1 * CAUSTIC_PAN1 * _Time.y, _WaveStrengthTexture).r;
    return (radius + strength * getwaves(p)) * rad;
}

float3 sea_height(float3 p, float radius, inout float height)
{
    float3 rad = normalize(p);
    float strength = SampleTexTriplanar(rad, 0.002 * p + TIME_FACTOR * 0.1 * CAUSTIC_PAN1 * _Time.y, _WaveStrengthTexture).r;
    float n = getwaves(p);
    height = strength * (n + 0.5 * SEA_HEIGHT) / SEA_HEIGHT;
    return (radius + strength * n) * rad;
}

v2f_planetOcean vert_planetOcean(appdata v, uint inst : SV_InstanceID)
{
    v2f_planetOcean o;
    
    float2 pInFace = v.vertex.xz;

    triangleBrickID geoMappingData = TriBrickIDMapping[ClusterMappingStartIndex + inst];
    OceanNodeData nodeData = _OceanNodeDatasBuffer[geoMappingData.dataId];
    float4x4 mat = _TransformDatasBuffer[nodeData.transformId];

    float oceanRadius = _PlanetOceanDatas[nodeData.planetId];

    float3 opos = nodeData.position + nodeData.size * (pInFace.x * nodeData.uAxis + pInFace.y * nodeData.vAxis);
    float3 rad = normalize(opos);
    //o.opos = sea_heightVertex(nodeData.radius * rad);
    o.opos = sea_heightVertex(oceanRadius * rad);
    
    float skirtFactor = 1;
    #ifdef UNDERWATER
        skirtFactor = -1;
    #endif
    //o.opos += 0.2 * skirtFactor * nodeData.radius * nodeData.size * v.vertex.y * rad; // add the side skirt
    o.opos += 0.2 * skirtFactor * oceanRadius * nodeData.size * v.vertex.y * rad; // add the side skirt

    o.wpos = mul(mat, float4(o.opos, 1));
    o.pos = mul(unity_MatrixVP, float4(o.wpos, 1));
    o.color = hsv2rgb(float3(frac(geoMappingData.dataId / 5.0), 0.9, 0.6));
    
    float sgn = nodeData.fadeTarget > 0.5? 1 : -1;
    o.crossfadeFactor = float4(
        sgn * saturate((_Time.y - nodeData.fadeTime) / FADE_TIME),
        sgn,
        oceanRadius, 0);
        //nodeData.radius, 0);

    o.data = int4(nodeData.planetId, nodeData.transformId, v.vertex.y < -0.01? 1 : 0, 0);

    #ifdef SHOW_WIREFRAME
        o.faceUV = pInFace;
    #endif

    return o;
}

v2f_planetOceanFog vert_planetOceanfog (appdata v)
{
    v2f_planetOceanFog o;
    
    o.pos = UnityObjectToClipPos(v.vertex);
    o.wpos = mul(unity_ObjectToWorld, float4(v.vertex.xyz, 1));
    //o.ray = UnityObjectToViewPos(float4(vPos,1)) * float3(-1,-1,1);

    return o;
}

float4 GetShoreFoam(float dDepth, float3 uv, float3 distort, float3 normal, float height, int planetId)
{

    float caustic = SampleTexTriplanar(normal, 4 * uv + CAUSTIC_PAN1 * distort * _SinTime.w, _CausticTex).r;

    // This gives a strong step to the caustic
    float threshold = 0.5 + 0.5 * smoothstep(0.1, 0.3, caustic); 

    // The coverage increase as the water depths gets smaller
    float shoreFoam = 1 - smoothstep(0, threshold, 0.5 * dDepth);

    float wave = smoothstep(0.1, 0.3, height);
    float waveFoam = wave * wave * (1 - smoothstep(0, threshold, max(0.3, 1 - wave)));
    float4 color = _PlanetOceanColorMainDatas[planetId];

    return saturate(0.6 * (shoreFoam * lerp(color, 1, 0.5) + waveFoam * lerp(color, 1, 0.3)));
    //return saturate(0.6 * (shoreFoam * lerp(_WaterColor1, 1, 0.5) + waveFoam * lerp(_WaterColor1, 1, 0.3)));
}

float4 GetSeabedCaustics(float3 pos, float radius, float3 normal)
{
    // TODO: use real light outscattering to damp effect.
    // Compute length and then extinction.
    float sceneWaterDepth = abs(length(pos) - radius);
    
    // Blend two caustic samples.
    // as in https://twitter.com/flogelz/status/1165251296720576512?s=20
    float3 coord = CAUSTIC_SCALE * pos;
    float4 caustic1 = SampleTexTriplanar(normal, coord + CAUSTIC_PAN1 * _Time.y, _CausticTex).r;
    float4 caustic2 = SampleTexTriplanar(normal, 0.99 * coord + CAUSTIC_PAN2 * _Time.y, _CausticTex).r;
    float4 caustic =  min(caustic1, caustic2);
    caustic.a = max(caustic.r, max(caustic.g, caustic.b));
    
    return CAUSTIC_STRENGTH * (1 - saturate(sceneWaterDepth / CAUSTIC_DEPTH)) * caustic;
}

float3 GetNormal(float3 coord, float3 rad, float radius, inout float height, float fadeFactor)
{
    // TODO: a bit crappy, we could use the 6 face cube axis, or the one from the node
    float3 tangent = normalize(cross(float3(1,1,1), rad));
    float3 binormal = normalize(cross(tangent, rad));

    float3 width = fwidth(coord);
    float eps = max(1, 2 * max(width.x, max(width.y, width.z)));
    float3 n = sea_height(coord, radius, height);
    float3 nt = sea_height(coord - eps * tangent, radius);
    float3 nb = sea_height(coord + eps * binormal, radius);

    // Todo: we should only need the last normalize
    float3 normal = normalize(cross(normalize(nt - n), normalize(nb - n)));

    return lerp(rad, normal, fadeFactor);
}

float GetSurfaceAlpha(float3 normal, float3 viewDir, out float fresnel)
{
    #ifdef UNDERWATER
    normal*=-1;
    #endif
    fresnel = saturate(pow(1 - abs(dot( -viewDir , normal )) , 5)) ;
    
    return lerp(_BaseAlpha, 1, fresnel);
}

float CameraClosePlaneHeightOverWave(float2 pos, int planetId)
{
    float3 wpos = GetClosePlaneWorldPosition(pos);
    float3 planetCenter = _PlanetShadowDatas[planetId];
    float oceanRadius = _PlanetOceanDatas[planetId].x;

    // Find the height of the wave at this point, and cull if we are above the water
    float3 opos = wpos - planetCenter; // Warning we do not take into acount the planet rotation
    float3 rad = normalize(opos);
    
    float noise = sea_height(oceanRadius * rad, rad);
    float oceanHeight = oceanRadius + noise;
    float pixelHeight = length(opos);
    return pixelHeight - oceanHeight;
}

// TODO: clean this and make separate functions
float4 frag_planetOcean (v2f_planetOcean i) : SV_Target
{
    CustomNewApplyDitherCrossFade(i.pos.xy, i.crossfadeFactor.x, i.crossfadeFactor.y);

    int planetId = GET_PLANET_ID_WATER(i);

    // We cull the skirt depending on pixel underwater state
    // TODO: we get an error if this is under an if. We only want to do this on a side skirt, so it could be nice to skip the computation.
    float pixelHeight = CameraClosePlaneHeightOverWave(i.pos, planetId);
    
    // Lets try to put it at the end
    /*#ifdef UNDERWATER
    clip(-pixelHeight);  
    #else
    clip(pixelHeight);  
    #endif*/ 

    float2 uv = float2(i.pos.x / _ScreenParams.x, i.pos.y / _ScreenParams.y);

    float waterZ = distance(i.wpos, _WorldSpaceCameraPos);
    float3 scenePos = WorldPosFromLastDepthTextureWithPos(i.pos);
    float sceneZ = distance(scenePos, _WorldSpaceCameraPos);
    
    // Needed to fade many effect, hide bugs and improve visual stability far away
    float fadeFactor = smoothstep(10000, 1000, waterZ);
    
    // Two bug happens:
    // 1) on the far cam doing the distance between two point will yield some instability when moving camera.
    // so we need to take the difference between the two distances
    // 2) on close camera the fog computation do not work well for high value of depth, when there is no scene depth
    //float minDepth = lerp(10, 0, fadeFactor);
    float waterDepth = min(max(0, sceneZ - waterZ), 100000);
    #ifdef UNDERWATER
        waterDepth = waterZ;
    #endif

    float3 viewDir = normalize(i.wpos - _WorldSpaceCameraPos);

    float4 waterFog = saturate(1 - exp(-waterDepth * _WaterDensity * _WaterExtinctionCoeff));

    #ifdef UNDERWATER
        //waterFog.a = 0;
    #endif

    float waterExtinction = 1 - waterFog.a;

    // Surface color and alpha
    float radius =  _PlanetOceanDatas[planetId].x;

    float3 rad = normalize(i.opos);
    float3 coord = 0.07 * i.opos;
    float height = 0;
    float3 normal = GetNormal(i.opos, rad, radius, height, fadeFactor);
    float fresnel = 0;
    
    float surfaceAlpha = GetSurfaceAlpha(normal, viewDir, fresnel);

    // Lighting of main surface.
    //float3 surface = _WaterColor1;
    float3 surface = _PlanetOceanColorMainDatas[planetId].rgb;
    //float planetDepthColor = _PlanetOceanColorDepthDatas[planetId];

    float4 caustics = 0;

    #ifndef UNDERWATER
        float4x4 matInv = _WorldToObjectBuffer[i.data.y];
        float3 scenePosPS = mul(matInv, float4(scenePos, 1));
        caustics = fadeFactor * GetSeabedCaustics(scenePosPS, radius, rad);
    #endif

    // Light params
    UnityLight light = MainLight();
    float3 atten = GetPlanetAttenuation(planetId, i.wpos);
    light.color *= atten;
    //float ambient = atten * AMBIENT_STRENGTH * _PlanetAmbientDatas[planetId] + unity_AmbientSky.rgb;
    //float3 ambient = AMBIENT_STRENGTH * _PlanetAmbientDatas[planetId] + unity_AmbientSky.rgb;
    float3 ambient = GetAmbientOnPlanet(planetId, i.wpos);
    
    float3 specular;
    float oneMinusReflectivity;
    surface = DiffuseAndSpecularFromMetallic(surface, 0, specular, oneMinusReflectivity);

    float roughness = lerp(_WaterRoughnessFar, _WaterRoughness, fadeFactor);
    
    surface  = BRDF1_Unity_PBS (
            surface, specular, 
            oneMinusReflectivity, roughness, 
            normal, -viewDir, 
            light, ZeroIndirect()) + ambient * surface;

    // Sky Reflection. From UnityStandBRDF.cginc
    surface += fresnel * saturate(_WaterRoughness + (1-oneMinusReflectivity)) * ambient;

    // Lighting values for various elements
    float3 ndl = atten * saturate(dot(normal, _WorldSpaceLightPos0.xyz)) * _LightColor0.rgb + ambient;
    float3 rdl = atten * saturate(dot(rad, _WorldSpaceLightPos0.xyz)) * _LightColor0.rgb + ambient;

    // Distort params ?
    float distortFactor = max(waterFog.a, 0.5) / max(waterZ, 1);
    #ifdef UNDERWATER
    distortFactor = 0.5 / waterZ;
    #endif

    float distortU = SampleTexTriplanar(rad, coord + 0.02 * _Time.y, _DistortionTexture).g;
    float distortV = SampleTexTriplanar(rad, coord + 0.03 * _Time.y, _DistortionTexture).g;

    float2 distort = 20 * distortFactor * (2 * float2(distortU , distortV) - 1);
    
    float2 distortUV = uv + fadeFactor * UV_Warp_Factor * distort * _DistortSceneBackground_TexelSize.xy;

    float4 shoreFoam = fadeFactor * GetShoreFoam(waterDepth, coord, 2 * float3(distortU, distortV, distortU) - 1, rad, height, planetId);
    
    float3 color =  surface * surfaceAlpha + (shoreFoam + waterExtinction * caustics.rgb) * ndl;

    // Build the underwater color.
    float3 sceneColor = tex2D(_DistortSceneBackground, distortUV);

    // TODO: make a wave color function
    // isolate the tip of the wave
    float3 waveFactor = saturate(4 * height * height - 0.1);
    
    // we simulate transluency of the wave. Sunlight hit the wave on the other side. Gives a greenish tint when facing the sun.
    float3 otherSideNormal = reflect(normal, rad);
    float sunIncidence = saturate(dot(otherSideNormal, -_WorldSpaceLightPos0.xyz));
    // Gives a greenish tint with standard extinction coeff
    float3 waveColor = lerp(_PlanetOceanColorSecDatas[planetId], (1-_WaterExtinctionCoeff) * _LightColor0.rgb, sunIncidence * waveFactor);

    //color = atten;
    //color = ambient;

    #ifdef UNDERWATER
        // TODO add the wave color somewhere
        float3 surfaceColor = color + (1 - surfaceAlpha) * sceneColor;
        color = waterFog.a * _PlanetOceanColorDepthDatas[planetId] * rdl + (1 - waterFog.rgb) * surfaceColor;
    #else
        float3 depthColor = waterFog.a * _PlanetOceanColorDepthDatas[planetId] * rdl + (1 - waterFog.rgb) * sceneColor;
        depthColor = lerp(depthColor, atten * waveColor, fadeFactor * waveFactor);
        color += (1 - surfaceAlpha) * (1 - shoreFoam.a) * depthColor;
    #endif
    
    #ifdef SHOW_WIREFRAME
        //color.rgb += DebugPolygonColor(pow(i.barycentricCoord, 1), i.color);
        float2 threshold = fwidth(2 * MESH_SIZE * i.faceUV.xy);
        float2 uvb = frac(2 * MESH_SIZE * i.faceUV.xy);
        float2 border = max(1 - smoothstep(0, threshold, uvb), smoothstep(1 - threshold, 1, uvb)) ;
        color.rgb += max(border.x, border.y) * i.color;
    #endif

    #ifdef SHOW_TESSELATION
        color.rgb += DebugPolygonColor(i.vertexWeight, i.color);
    #endif

    #ifdef UNDERWATER
    clip(-pixelHeight);  
    #else
    clip(pixelHeight);  
    #endif 
    
    return float4(color, 1);
}

float4 frag_planetOceanAMD1 (v2f_planetOcean i) : SV_Target
{
    CustomNewApplyDitherCrossFade(i.pos.xy, i.crossfadeFactor.x, i.crossfadeFactor.y);

    int planetId = GET_PLANET_ID_WATER(i);

    // We cull the skirt depending on pixel underwater state
    // TODO: we get an error if this is under an if. We only want to do this on a side skirt, so it could be nice to skip the computation.
    float pixelHeight = CameraClosePlaneHeightOverWave(i.pos, planetId);
    
    /*#ifdef UNDERWATER
    clip(-pixelHeight);  
    #else
    clip(pixelHeight);  
    #endif */

    float2 uv = float2(i.pos.x / _ScreenParams.x, i.pos.y / _ScreenParams.y);

    float waterZ = distance(i.wpos, _WorldSpaceCameraPos);
    float3 scenePos = WorldPosFromLastDepthTextureWithPos(i.pos);
    float sceneZ = distance(scenePos, _WorldSpaceCameraPos);
    
    // Needed to fade many effect, hide bugs and improve visual stability far away
    float fadeFactor = smoothstep(10000, 1000, waterZ);
    
    // Two bug happens:
    // 1) on the far cam doing the distance between two point will yield some instability when moving camera.
    // so we need to take the difference between the two distances
    // 2) on close camera the fog computation do not work well for high value of depth, when there is no scene depth
    //float minDepth = lerp(10, 0, fadeFactor);
    float waterDepth = min(max(0, sceneZ - waterZ), 100000);
    #ifdef UNDERWATER
        waterDepth = waterZ;
    #endif

    float3 viewDir = normalize(i.wpos - _WorldSpaceCameraPos);

    float4 waterFog = saturate(1 - exp(-waterDepth * _WaterDensity * _WaterExtinctionCoeff));

    #ifdef UNDERWATER
        //waterFog.a = 0;
    #endif

    float waterExtinction = 1 - waterFog.a;

    // Surface color and alpha
    float radius =  _PlanetOceanDatas[planetId].x;

    float3 rad = normalize(i.opos);
    float3 coord = 0.07 * i.opos;
    float height = 0;
    float3 normal = GetNormal(i.opos, rad, radius, height, fadeFactor);
    float fresnel = 0;
    
    float surfaceAlpha = GetSurfaceAlpha(normal, viewDir, fresnel);

    // Lighting of main surface.
    //float3 surface = _WaterColor1;
    float3 surface = _PlanetOceanColorMainDatas[planetId].rgb;
    //float planetDepthColor = _PlanetOceanColorDepthDatas[planetId];

    float4 caustics = 0;

    #ifndef UNDERWATER
        float4x4 matInv = _WorldToObjectBuffer[i.data.y];
        float3 scenePosPS = mul(matInv, float4(scenePos, 1));
        caustics = fadeFactor * GetSeabedCaustics(scenePosPS, radius, rad);
    #endif

    // Light params
    UnityLight light = MainLight();
    float3 atten = GetPlanetAttenuation(planetId, i.wpos);
    light.color *= atten;
    //float ambient = atten * AMBIENT_STRENGTH * _PlanetAmbientDatas[planetId] + unity_AmbientSky.rgb;
    //float3 ambient = AMBIENT_STRENGTH * _PlanetAmbientDatas[planetId] + unity_AmbientSky.rgb;
    float3 ambient = GetAmbientOnPlanet(planetId, i.wpos);
    
    float3 specular;
    float oneMinusReflectivity;
    surface = DiffuseAndSpecularFromMetallic(surface, 0, specular, oneMinusReflectivity);

    float roughness = lerp(_WaterRoughnessFar, _WaterRoughness, fadeFactor);
    
    surface  = BRDF1_Unity_PBS (
            surface, specular, 
            oneMinusReflectivity, roughness, 
            normal, -viewDir, 
            light, ZeroIndirect()) + ambient * surface;

    // Sky Reflection. From UnityStandBRDF.cginc
    surface += fresnel * saturate(_WaterRoughness + (1-oneMinusReflectivity)) * ambient;

    // Lighting values for various elements
    float3 ndl = atten * saturate(dot(normal, _WorldSpaceLightPos0.xyz)) * _LightColor0.rgb + ambient;
    float3 rdl = atten * saturate(dot(rad, _WorldSpaceLightPos0.xyz)) * _LightColor0.rgb + ambient;

    // Distort params ?
    float distortFactor = max(waterFog.a, 0.5) / max(waterZ, 1);
    #ifdef UNDERWATER
    distortFactor = 0.5 / waterZ;
    #endif

    float distortU = SampleTexTriplanar(rad, coord + 0.02 * _Time.y, _DistortionTexture).g;
    float distortV = SampleTexTriplanar(rad, coord + 0.03 * _Time.y, _DistortionTexture).g;

    float2 distort = 20 * distortFactor * (2 * float2(distortU , distortV) - 1);
    
    float2 distortUV = uv + fadeFactor * UV_Warp_Factor * distort * _DistortSceneBackground_TexelSize.xy;

    float4 shoreFoam = fadeFactor * GetShoreFoam(waterDepth, coord, 2 * float3(distortU, distortV, distortU) - 1, rad, height, planetId);
    
    float3 color =  surface * surfaceAlpha + (shoreFoam + waterExtinction * caustics.rgb) * ndl;

    // Build the underwater color.
    float3 sceneColor = tex2D(_DistortSceneBackground, distortUV);

    // TODO: make a wave color function
    // isolate the tip of the wave
    float3 waveFactor = saturate(4 * height * height - 0.1);
    
    // we simulate transluency of the wave. Sunlight hit the wave on the other side. Gives a greenish tint when facing the sun.
    float3 otherSideNormal = reflect(normal, rad);
    float sunIncidence = saturate(dot(otherSideNormal, -_WorldSpaceLightPos0.xyz));
    // Gives a greenish tint with standard extinction coeff
    float3 waveColor = lerp(_PlanetOceanColorSecDatas[planetId], (1-_WaterExtinctionCoeff) * _LightColor0.rgb, sunIncidence * waveFactor);

    //color = atten;
    //color = ambient;

    #ifdef UNDERWATER
        // TODO add the wave color somewhere
        float3 surfaceColor = color + (1 - surfaceAlpha) * sceneColor;
        color = waterFog.a * _PlanetOceanColorDepthDatas[planetId] * rdl + (1 - waterFog.rgb) * surfaceColor;
    #else
        float3 depthColor = waterFog.a * _PlanetOceanColorDepthDatas[planetId] * rdl + (1 - waterFog.rgb) * sceneColor;
        depthColor = lerp(depthColor, atten * waveColor, fadeFactor * waveFactor);
        color += (1 - surfaceAlpha) * (1 - shoreFoam.a) * depthColor;
    #endif
    
    #ifdef SHOW_WIREFRAME
        //color.rgb += DebugPolygonColor(pow(i.barycentricCoord, 1), i.color);
        float2 threshold = fwidth(2 * MESH_SIZE * i.faceUV.xy);
        float2 uvb = frac(2 * MESH_SIZE * i.faceUV.xy);
        float2 border = max(1 - smoothstep(0, threshold, uvb), smoothstep(1 - threshold, 1, uvb)) ;
        color.rgb += max(border.x, border.y) * i.color;
    #endif

    #ifdef SHOW_TESSELATION
        color.rgb += DebugPolygonColor(i.vertexWeight, i.color);
    #endif

    color.r += saturate(0.01 * pixelHeight);
    
    return float4(color, 1);
}

float4 frag_planetOceanFog (v2f_planetOceanFog i) : SV_Target
{
    // Get the position and cull if below the wave
    float pixelHeightOverWave = CameraClosePlaneHeightOverWave(i.pos, _PlanetId);

    if(-pixelHeightOverWave + 0.1 < 0)
    {
        // Compute atmosphere
        v2f_planetAtmosphere atmosphereFragData;
        atmosphereFragData.pos = i.pos;
        atmosphereFragData.wpos = i.wpos;
        
        return frag_PlanetAtmosphere(atmosphereFragData);
    }
    
    float3 scenePos = WorldPosFromLastDepthTextureWithPos(i.pos);
    float sceneDepth = distance(scenePos, _WorldSpaceCameraPos);

    float4 waterFog = saturate(1 - exp(-sceneDepth * _WaterDensity * _WaterExtinctionCoeff));
    float waterExtinction = 1 - waterFog.a;

    float3 scenePosPS = scenePos - _PlanetCenter;
    float oceanRadius = _PlanetOceanDatas[_PlanetId].x;
    float4 caustics = GetSeabedCaustics(scenePosPS, oceanRadius, normalize(scenePosPS));

    float3 rad = normalize(i.wpos - _PlanetCenter);
    float atten = 1; // TODO: do the real shadow here
    float ambient = atten * AMBIENT_STRENGTH * _PlanetAmbientDatas[_PlanetId]; 
    float3 rdl = atten * saturate(dot(rad, _WorldSpaceLightPos0.xyz)) * _LightColor0.rgb + ambient;
    float3 color = waterFog.a * _PlanetOceanColorDepthDatas[_PlanetId] * rdl + 1.2 * waterExtinction * caustics.rgb * rdl;
    float alpha = 1 - (1 - waterFog.a) * (1 - caustics.a);

    return float4(color, alpha);
}    