/*
 * MIT License
 *
 * Copyright(c) 2019 Asif Ali
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

void GetMaterial(inout State state, in Ray r)
{
    int index = state.matID * 8;
    Material mat;
    Medium medium;

    vec4 param1 = texelFetch(materialsTex, ivec2(index + 0, 0), 0);
    vec4 param2 = texelFetch(materialsTex, ivec2(index + 1, 0), 0);
    vec4 param3 = texelFetch(materialsTex, ivec2(index + 2, 0), 0);
    vec4 param4 = texelFetch(materialsTex, ivec2(index + 3, 0), 0);
    vec4 param5 = texelFetch(materialsTex, ivec2(index + 4, 0), 0);
    vec4 param6 = texelFetch(materialsTex, ivec2(index + 5, 0), 0);
    vec4 param7 = texelFetch(materialsTex, ivec2(index + 6, 0), 0);
    vec4 param8 = texelFetch(materialsTex, ivec2(index + 7, 0), 0);

    mat.baseColor          = param1.rgb;
    mat.anisotropic        = param1.w;

    mat.emission           = param2.rgb;

    mat.metallic           = param3.x;
    mat.roughness          = max(param3.y, 0.001);
    mat.subsurface         = param3.z;
    mat.specularTint       = param3.w;

    mat.sheen              = param4.x;
    mat.sheenTint          = param4.y;
    mat.clearcoat          = param4.z;
    mat.clearcoatRoughness = mix(0.1, 0.001, param4.w); // Remapping from gloss to roughness

    mat.specTrans          = param5.x;
    mat.ior                = param5.y;
    mat.medium.type        = int(param5.z);
    mat.medium.density     = param5.w;

    mat.medium.color       = param6.rgb;
    mat.medium.anisotropy  = clamp(param6.w, -0.9, 0.9);

    ivec4 texIDs           = ivec4(param7);

    mat.opacity            = param8.x;
    mat.alphaMode          = int(param8.y);
    mat.alphaCutoff        = param8.z;

    // Base Color Map
    if (texIDs.x >= 0)
    {
        vec4 col = texture(textureMapsArrayTex, vec3(state.texCoord, texIDs.x));
        mat.baseColor.rgb *= pow(col.rgb, vec3(2.2));
        mat.opacity *= col.a;
    }

    // Metallic Roughness Map
    if (texIDs.y >= 0)
    {
        vec2 matRgh = texture(textureMapsArrayTex, vec3(state.texCoord, texIDs.y)).bg;
        mat.metallic = matRgh.x;
        mat.roughness = max(matRgh.y * matRgh.y, 0.001);
    }

    // Normal Map
    if (texIDs.z >= 0)
    {
        vec3 texNormal = texture(textureMapsArrayTex, vec3(state.texCoord, texIDs.z)).rgb;

#ifdef OPT_OPENGL_NORMALMAP
        texNormal.y = 1.0 - texNormal.y;
#endif
        texNormal = normalize(texNormal * 2.0 - 1.0);

        vec3 origNormal = state.normal;
        state.normal = normalize(state.tangent * texNormal.x + state.bitangent * texNormal.y + state.normal * texNormal.z);
        state.ffnormal = dot(origNormal, r.direction) <= 0.0 ? state.normal : -state.normal;
    }

#ifdef OPT_ROUGHNESS_MOLLIFICATION
    if(state.depth > 0)
        mat.roughness = max(mix(0.0, state.mat.roughness, roughnessMollificationAmt), mat.roughness);
#endif

    // Emission Map
    if (texIDs.w >= 0)
        mat.emission = pow(texture(textureMapsArrayTex, vec3(state.texCoord, texIDs.w)).rgb, vec3(2.2));

    float aspect = sqrt(1.0 - mat.anisotropic * 0.9);
    mat.ax = max(0.001, mat.roughness / aspect);
    mat.ay = max(0.001, mat.roughness * aspect);

    state.mat = mat;
    state.eta = dot(r.direction, state.normal) < 0.0 ? (1.0 / mat.ior) : mat.ior;
}

vec3 DirectLight(in Ray r, in State state, bool isSurface)
{
    vec3 Ld = vec3(0.0);
    vec3 Li = vec3(0.0);
    vec3 scatterPos = state.fhp + state.normal * EPS;

    ScatterSampleRec scatterSample;

    // Environment Light
#ifdef OPT_ENVMAP
#ifndef OPT_UNIFORM_LIGHT
    {
        vec3 color;
        vec4 dirPdf = SampleEnvMap(Li);
        vec3 lightDir = dirPdf.xyz;
        float lightPdf = dirPdf.w;

        Ray shadowRay = Ray(scatterPos, lightDir);

        // If there are no volumes in the scene then use a simple binary hit test
        bool inShadow = AnyHit(shadowRay, INF - EPS);

        if (!inShadow)
        {
            scatterSample.f = DisneyEval(state, -r.direction, state.ffnormal, lightDir, scatterSample.pdf);

            if (scatterSample.pdf > 0.0)
            {
                float misWeight = PowerHeuristic(lightPdf, scatterSample.pdf);
                if (misWeight > 0.0)
                    Ld += misWeight * Li * scatterSample.f * envMapIntensity / lightPdf;
            }
        }

    }
#endif
#endif

    // Analytic Lights
#ifdef OPT_LIGHTS
    {
        LightSampleRec lightSample;
        Light light;

        //Pick a light to sample
        int index = int(rand() * float(numOfLights)) * 5;

        // Fetch light Data
        vec3 position = texelFetch(lightsTex, ivec2(index + 0, 0), 0).xyz;
        vec3 emission = texelFetch(lightsTex, ivec2(index + 1, 0), 0).xyz;
        vec3 u        = texelFetch(lightsTex, ivec2(index + 2, 0), 0).xyz; // u vector for rect
        vec3 v        = texelFetch(lightsTex, ivec2(index + 3, 0), 0).xyz; // v vector for rect
        vec3 params   = texelFetch(lightsTex, ivec2(index + 4, 0), 0).xyz;
        float radius  = params.x;
        float area    = params.y;
        float type    = params.z; // 0->Rect, 1->Sphere, 2->Distant

        light = Light(position, emission, u, v, radius, area, type);
        SampleOneLight(light, scatterPos, lightSample);
        Li = lightSample.emission;

        if (dot(lightSample.direction, lightSample.normal) < 0.0) // Required for quad lights with single sided emission
        {
            Ray shadowRay = Ray(scatterPos, lightSample.direction);

            // If there are no volumes in the scene then use a simple binary hit test
            bool inShadow = AnyHit(shadowRay, lightSample.dist - EPS);

            if (!inShadow)
            {
                scatterSample.f = DisneyEval(state, -r.direction, state.ffnormal, lightSample.direction, scatterSample.pdf);

                float misWeight = 1.0;
                if(light.area > 0.0) // No MIS for distant light
                    misWeight = PowerHeuristic(lightSample.pdf, scatterSample.pdf);

                if (scatterSample.pdf > 0.0)
                    Ld += misWeight * Li * scatterSample.f / lightSample.pdf;
            }

        }
    }
#endif

    return Ld;
}

vec4 PathTrace(Ray r)
{
    vec3 radiance = vec3(0.0);
    vec3 throughput = vec3(1.0);
    State state;
    LightSampleRec lightSample;
    ScatterSampleRec scatterSample;

    // FIXME: alpha from material opacity/medium density
    float alpha = 1.0;

    // For medium tracking
    bool inMedium = false;
    bool mediumSampled = false;
    bool surfaceScatter = false;

    for (state.depth = 0;; state.depth++)
    {
        bool hit = ClosestHit(r, state, lightSample);

        if (!hit)
        {
            #if defined(OPT_BACKGROUND) || defined(OPT_TRANSPARENT_BACKGROUND)
            if (state.depth == 0)
                alpha = 0.0;
            #endif

            #ifdef OPT_UNIFORM_LIGHT
             radiance += uniformLightCol * throughput;
            #else
            #ifdef OPT_ENVMAP
            vec4 envMapColPdf = EvalEnvMap(r);

            float misWeight = 1.0;

            // Gather radiance from envmap and use scatterSample.pdf from previous bounce for MIS
            if (state.depth > 0)
                misWeight = PowerHeuristic(scatterSample.pdf, envMapColPdf.w);

            if(misWeight > 0)
                radiance += misWeight * envMapColPdf.rgb * throughput * envMapIntensity;
            #endif
            #endif

             break;
        }

        GetMaterial(state, r);

        // Gather radiance from emissive objects. Emission from meshes is not importance sampled
        radiance += state.mat.emission * throughput;
        
        #ifdef OPT_LIGHTS
        // Gather radiance from light and use scatterSample.pdf from previous bounce for MIS
        if (state.isEmitter)
        {
            float misWeight = 1.0;

            if (state.depth > 0)
                misWeight = PowerHeuristic(scatterSample.pdf, lightSample.pdf);

            radiance += misWeight * lightSample.emission * throughput;

            break;
        }
        #endif

        // Stop tracing ray if maximum depth was reached
        if(state.depth == maxDepth)
            break;

            #ifdef OPT_ALPHA_TEST

            // Ignore intersection and continue ray based on alpha test
            if ((state.mat.alphaMode == ALPHA_MODE_MASK && state.mat.opacity < state.mat.alphaCutoff) ||
                (state.mat.alphaMode == ALPHA_MODE_BLEND && rand() > state.mat.opacity))
            {
                scatterSample.L = r.direction;
                state.depth--;
            }
            else
            #endif
            {
                surfaceScatter = true;

                // Next event estimation
                radiance += DirectLight(r, state, true) * throughput;

                // Sample BSDF for color and outgoing direction
                scatterSample.f = DisneySample(state, -r.direction, state.ffnormal, scatterSample.L, scatterSample.pdf);
                if (scatterSample.pdf > 0.0)
                    throughput *= scatterSample.f / scatterSample.pdf;
                else
                    break;
            }

            // Move ray origin to hit point and set direction for next bounce
            r.direction = scatterSample.L;
            r.origin = state.fhp + r.direction * EPS;

        #ifdef OPT_RR
        // Russian roulette
        if (state.depth >= OPT_RR_DEPTH)
        {
            float q = min(max(throughput.x, max(throughput.y, throughput.z)) + 0.001, 0.95);
            if (rand() > q)
                break;
            throughput /= q;
        }
        #endif

    }

    return vec4(radiance, alpha);
}