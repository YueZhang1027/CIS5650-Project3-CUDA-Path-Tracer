#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/partition.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 0

#define DISPLAY_GBUFFER_NORMAL 1
#define DISPLAY_GBUFFER_POSITION 0
#define DISPLAY_GBUFFER_DUMMY 0

#define USE_GAUSSIAN 0
#define sigma 5.0

#define SORT_MATERIALS 0
#define FIRST_BOUNCE_CACHE 0
#define ANTI_ALIASING 0

#define SIMPLE 0
#define NAIVE 1
#define DIRECT_MIS 0
#define FULL 0
#define RUSSIAN_ROULETTE 0

#define SUB_SCATTERING 0

#define USE_KD_TREE 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char* msg, const char* file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

struct isPathValid {
	__host__ __device__
		bool operator()(const PathSegment& x)
	{
		return x.remainingBounces > 0;
	}
};

struct compareByMaterialId {
	__host__ __device__
		bool operator()(const ShadeableIntersection& x, const ShadeableIntersection& y)
	{
		return x.materialId < y.materialId;
	}
};

__global__ void copyImage(glm::ivec2 resolution, int iter, glm::vec3* image, glm::vec3* denoisedImage) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + resolution.x * y;
		denoisedImage[index] = image[index] / (float)iter;
	}
}

__global__ void restoreImage(glm::ivec2 resolution, int iter, glm::vec3* denoisedImage) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + resolution.x * y;
		denoisedImage[index] *= (float)iter;
	}
}

__host__ __device__ glm::vec3 restoreZdepth(float z, int x, int y, Camera cam) {
	if (z < 0) { 
		return glm::vec3(0.f); 
	}
	Ray ray;
	ray.direction = glm::normalize(cam.view
		- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
		- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
	);
	ray.origin = cam.position;

	return getPointOnRay(ray, z);
}

__host__ __device__ glm::vec3 decodeOct(glm::vec2 oct) {
	glm::vec3 v(oct.x, oct.y, 1.0 - abs(oct.x) - abs(oct.y));
	if (v.z < 0) {
		glm::vec2 xy = (1.0f - glm::vec2(v.y, v.x)) * 
			glm::vec2((v.x >= 0.0) ? +1.0 : -1.0, (v.y >= 0.0) ? +1.0 : -1.0);
		v.x = xy.x;
		v.y = xy.y;
	}
	return normalize(v);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

__global__ void gbufferToPBO(uchar4* pbo, Camera cam, GBufferPixel* gBuffer) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	glm::ivec2 resolution = cam.resolution;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);

		pbo[index].w = 0;
#if DISPLAY_GBUFFER_DUMMY
		//float timeToIntersect = gBuffer[index].t * 255.0;
		//pbo[index].x = timeToIntersect;
		//pbo[index].y = timeToIntersect;
		//pbo[index].z = timeToIntersect;
#elif DISPLAY_GBUFFER_NORMAL
		// display normal
		#if GBUFFER_OCT
			glm::vec3 display_nor = abs(decodeOct(gBuffer[index].oct_normal)) * 255.0f;
		#else
			glm::vec3 display_nor = abs(gBuffer[index].normal) * 255.0f;
		#endif
		pbo[index].x = display_nor.x;
		pbo[index].y = display_nor.y;
		pbo[index].z = display_nor.z;
#elif DISPLAY_GBUFFER_POSITION
		// display position
		#if GBUFFER_Z
			glm::vec3 display_pos = abs(restoreZdepth(gBuffer[index].z, x, y, cam)) * 255.0f / 10.0f;
		#else
			glm::vec3 display_pos = abs(gBuffer[index].position) * 255.0f / 10.0f;
		#endif

		// different scale for cornnel box scene
		pbo[index].x = display_pos.x;
		pbo[index].y = display_pos.y;
		pbo[index].z = display_pos.z;
#endif
	}
}

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3* dev_image = NULL;
static Geom* dev_geoms = NULL;
static Light* dev_lights = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static ShadeableIntersection* dev_intersections = NULL;

static GBufferPixel* dev_gBuffer = NULL;
static glm::vec3* dev_denoised_image = NULL;
static glm::vec3* dev_denoised_image_next = NULL;
#if USE_GAUSSIAN
static float* dev_gaussian_kernel = NULL;
static float lastFilterSize = 0.f;
#endif

#if FIRST_BOUNCE_CACHE
static ShadeableIntersection* dev_first_bounce_cache = NULL;
#endif

static KDAccelNode* dev_kdNodes = NULL;
static glm::vec3* dev_envmap = NULL;

static glm::vec3* dev_texturemaps = NULL;
static TextureInfo* dev_textureInfos = NULL;

// TODO: static variables for device memory, any extra info you need, etc
// ...

void InitDataContainer(GuiDataContainer* imGuiData)
{
	guiData = imGuiData;
}

void pathtraceInit(Scene* scene) {
	hst_scene = scene;

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

#if USE_KD_TREE
	cudaMalloc(&dev_geoms, scene->sortedGeoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->sortedGeoms.data(), scene->sortedGeoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);
#else
	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);
#endif // USE_KD_TREE
	
	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	// TODO: initialize any extra device memeory you need
#if FIRST_BOUNCE_CACHE
	cudaMalloc(&dev_first_bounce_cache, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_first_bounce_cache, 0, pixelcount * sizeof(ShadeableIntersection));
#endif

	// lights
	cudaMalloc(&dev_lights, scene->lights.size() * sizeof(Light));
	cudaMemcpy(dev_lights, scene->lights.data(), scene->lights.size() * sizeof(Light), cudaMemcpyHostToDevice);

	// kd tree
#if USE_KD_TREE
	cudaMalloc(&dev_kdNodes, scene->kdNodes.size() * sizeof(KDAccelNode));
	cudaMemcpy(dev_kdNodes, scene->kdNodes.data(), scene->kdNodes.size() * sizeof(KDAccelNode), cudaMemcpyHostToDevice);
#endif

	// environment map
	if (scene->hdrImage.size() > 0) {
		cudaMalloc(&dev_envmap, scene->hdrImage.size() * sizeof(glm::vec3));
		cudaMemcpy(dev_envmap, scene->hdrImage.data(), scene->hdrImage.size() * sizeof(glm::vec3), cudaMemcpyHostToDevice);
	}

	// texture map
	if (scene->textureInfos.size() > 0) {
		cudaMalloc(&dev_texturemaps, scene->textures.size() * sizeof(glm::vec3));
		cudaMemcpy(dev_texturemaps, scene->textures.data(), scene->textures.size() * sizeof(glm::vec3), cudaMemcpyHostToDevice);
	
		cudaMalloc(&dev_textureInfos, scene->textureInfos.size() * sizeof(TextureInfo));
		cudaMemcpy(dev_textureInfos, scene->textureInfos.data(), scene->textureInfos.size() * sizeof(TextureInfo), cudaMemcpyHostToDevice);
	}

	cudaMalloc(&dev_gBuffer, pixelcount * sizeof(GBufferPixel));
	cudaMemset(dev_gBuffer, 0, pixelcount * sizeof(GBufferPixel));

	cudaMalloc(&dev_denoised_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_denoised_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_denoised_image_next, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_denoised_image_next, 0, pixelcount * sizeof(glm::vec3));

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);
	cudaFree(dev_geoms);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	// TODO: clean up any extra device memory you created

#if FIRST_BOUNCE_CACHE
	cudaFree(dev_first_bounce_cache);
#endif

	cudaFree(dev_lights);

#if USE_KD_TREE
	cudaFree(dev_kdNodes);
#endif

	if (dev_envmap != NULL) {
		cudaFree(dev_envmap);
	}

	if (dev_texturemaps != NULL) {
		cudaFree(dev_texturemaps);
		cudaFree(dev_textureInfos);
	}

	cudaFree(dev_gBuffer);
	cudaFree(dev_denoised_image);
	cudaFree(dev_denoised_image_next);

#if USE_GAUSSIAN
	if (dev_gaussian_kernel != NULL) {
		cudaFree(dev_gaussian_kernel);
	}
#endif

	checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment& segment = pathSegments[index];

		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, traceDepth);
		thrust::uniform_real_distribution<float> u01(0, 1);

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(0.0f, 0.0f, 0.0f);
		segment.throughput = glm::vec3(1.0f, 1.0f, 1.0f);

		segment.isFromCamera = true;
		segment.isSpecularBounce = false;

		// anti-aliasing by jittering
		// u01(rng) - 0.5f
		glm::vec2 bias(0.0f);
#if ANTI_ALIASING
		bias = glm::vec2(u01(rng) - 0.5f, u01(rng) - 0.5f);
#endif
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x + bias.x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y + bias.y - (float)cam.resolution.y * 0.5f)
		);

		// Physically-based depth-of-field
		if (cam.lensRadius > 0.0f) {
			// generate random point on lens
			glm::vec2 sample = glm::vec2(u01(rng), u01(rng));
			glm::vec2 pLens = cam.lensRadius * concentricSampleDisk(sample);

			// compute point on plane of focus
			float ft = glm::abs(cam.focalDistance / segment.ray.direction.z);
			glm::vec3 pFocus = segment.ray.origin + ft * segment.ray.direction;

			// update ray for effect of lens
			segment.ray.origin += cam.right * pLens.x + cam.up * pLens.y;
			segment.ray.direction = glm::normalize(pFocus - segment.ray.origin);
		}

		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
		segment.russianRouletteThres = traceDepth - 3;

		// medium
		segment.medium.valid = false;
		segment.tFar = cam.farClip;
		segment.hitSurface = false;
	}
}


// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment* pathSegments
	, Geom* geoms
	, int geoms_size
	, ShadeableIntersection* intersections
)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];
		intersections[path_index].t = FLT_MAX;
		computeRayIntersection(geoms, geoms_size, pathSegment.ray, intersections[path_index]);
	}
}

__global__ void computeIntersectionsFromKDTree(
	int depth
	, int num_paths
	, PathSegment* pathSegments
	, KDAccelNode* nodes
	, int node_size
	, Geom* geoms
	, ShadeableIntersection* intersections
)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];
		intersections[path_index].t = FLT_MAX;
		computeRayIntersectionFromKdTree(geoms, nodes, node_size, pathSegment.ray, intersections[path_index]);
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
		  // Set up the RNG
		  // LOOK: this is how you use thrust's RNG! Please look at
		  // makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (materialColor * material.emittance);
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
				pathSegments[idx].color *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
				pathSegments[idx].color *= u01(rng); // apply some noise because why not
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		}
		else {
			pathSegments[idx].color = glm::vec3(0.0f);
		}
	}
}

// naive path tracing
__global__ void shadeNaive(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
	, glm::vec3* envmap
	, int envmapWidth
	, int envmapHeight
	, int numLights
	, TextureInfo* textureInfos
	, glm::vec3* texturemaps
	
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		PathSegment& cur = pathSegments[idx];
		if (intersection.t > 0.0) { // if the intersection exists...
			// Set up the RNG
			// LOOK: this is how you use thrust's RNG! Please look at
			// makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);

			Material material = materials[intersection.materialId];

			if (material.albedoTex != -1) {
				// sample texture
				int width = textureInfos[material.albedoTex].width;
				int height = textureInfos[material.albedoTex].height;
				int offset = textureInfos[material.albedoTex].offset;

				int w = (int)((float)width * intersection.uv[0] - 0.5f);
				int h = (int)((float)height * (1.0f - intersection.uv[1]) - 0.5f);
				materials[intersection.materialId].color = texturemaps[h * width + w + offset];
			}

			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				cur.color += cur.throughput * (materialColor * material.emittance);
				cur.remainingBounces = 0; // terminate path
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				scatterRay(cur,
					getPointOnRay(cur.ray, intersection.t),
					intersection.surfaceNormal, material, rng);
				if (cur.remainingBounces == 0) {
					cur.color += cur.throughput;
				}
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		} else {
			if (envmap != NULL) {
				cur.color = cur.throughput * getEnvLight(envmap, envmapWidth, envmapHeight, cur.ray.direction, numLights);
			}
			cur.remainingBounces = 0; // terminate path
		}
	}
}

// multi importance sampling
__global__ void shadeDirectMIS(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
	, Geom* geoms
	, int numGeoms
	, KDAccelNode* nodes
	, int node_size
	, Light* lights
	, int numLights
	, glm::vec3* envmap
	, int envmapWidth
	, int envmapHeight
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		PathSegment& cur = pathSegments[idx];

		if (intersection.t > 0.0) { // if the intersection exists...
			// Set up the RNG
			// LOOK: this is how you use thrust's RNG! Please look at
			// makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			cur.color = glm::vec3(0.0f);

			Material material = materials[intersection.materialId];
			glm::vec3 point = getPointOnRay(cur.ray, intersection.t);

			if (material.emittance > 0.0f) {
				cur.color = material.color * material.emittance;
				cur.remainingBounces = 0; // terminate path
			} else {
				cur.color = sampleUniformLight(
					point, intersection, cur.ray.direction, materials, geoms, numGeoms,
#if USE_KD_TREE
					nodes, node_size,
#else
					NULL, 0,
#endif
					lights, numLights, envmap, envmapWidth, envmapHeight, rng);
				cur.remainingBounces = 0;
			}
		} else {
			if (envmap != NULL) {
				cur.color = cur.throughput * getEnvLight(envmap, envmapWidth, envmapHeight, cur.ray.direction, numLights);
			}
			cur.remainingBounces = 0; // terminate path
		}
	}
}

// full light integrator
__global__ void shadeFull(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
	, Geom* geoms
	, int numGeoms
	, KDAccelNode* nodes
	, int node_size
	, Light* lights
	, int numLights
	, glm::vec3* envmap
	, int envmapWidth
	, int envmapHeight
	, TextureInfo* textureInfos
	, glm::vec3* texturemaps
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		PathSegment& cur = pathSegments[idx];
		if (intersection.t > 0.0) { // if the intersection exists...
			// Set up the RNG
			// LOOK: this is how you use thrust's RNG! Please look at
			// makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			Material material = materials[intersection.materialId];

			if (material.albedoTex != -1) {
				// sample texture
				int width = textureInfos[material.albedoTex].width;
				int height = textureInfos[material.albedoTex].height;
				int offset = textureInfos[material.albedoTex].offset;

				int w = (int)((float)width * intersection.uv[0] - 0.5f);
				int h = (int)((float)height * (1.0f - intersection.uv[1]) - 0.5f);
				materials[intersection.materialId].color = texturemaps[h * width + w + offset];
			}

			glm::vec3 point = getPointOnRay(cur.ray, intersection.t);

			cur.hitSurface = true;

			// calculate transmission
#if SUB_SCATTERING
			sampleTransmission(cur, intersection.t, rng);

			if (!cur.hitSurface) {
				return;
			}
#endif // SUB_SCATTERING

			// specular or direct from camera
			if (material.emittance > 0.0f) {
				if (cur.isFromCamera || cur.isSpecularBounce) {
					// If the material indicates that the object was a light, "light" the ray
					cur.color += cur.throughput * material.color * material.emittance;
				}
				cur.remainingBounces = 0; // terminate path
				return;
			}
			cur.isFromCamera = false; 
			cur.isSpecularBounce = false;

			// If the surface is diffuse or microfacet, compute MIS direct light
			if (material.type == MaterialType::DIFFUSE ||
				material.type == MaterialType::MICROFACET) {
				glm::vec3 Ld = sampleUniformLight(
					point, intersection, cur.ray.direction, materials, geoms, numGeoms,
#if USE_KD_TREE
					nodes, node_size,
#else
					NULL, 0,
#endif
					lights, numLights, envmap, envmapWidth, envmapHeight, rng);
				cur.color += Ld * cur.throughput;
			}

			// Sample BSDF
			scatterRay(cur, point, intersection.surfaceNormal, material, rng);
				
#if SUB_SCATTERING
			cur.medium.valid = false;
			// if transimission, setup medium
			if (material.type == MaterialType::SPEC_TRANS ||
				material.type == MaterialType::SPEC_FRESNEL) {
				// copy medium
				cur.medium.valid = material.medium.valid;
				cur.medium.absorptionCoefficient = material.medium.absorptionCoefficient;
				cur.medium.scatteringCoefficient = material.medium.scatteringCoefficient;
				cur.medium.mediumType = material.medium.mediumType;
			}
#endif

			// russian roulette
#if RUSSIAN_ROULETTE
			if (cur.remainingBounces < cur.russianRouletteThres) {
				float p = max(cur.throughput.x, max(cur.throughput.y, cur.throughput.z));
				thrust::uniform_real_distribution<float> u01(0, 1);
				if (u01(rng) > p) {
					cur.remainingBounces = 0; // terminate path
					return;
				}

				cur.throughput *= 1.0f / p;
			}
#endif
		}
		else {
			// invalid colors
			if ((cur.isFromCamera || cur.isSpecularBounce) && envmap != NULL) {
				cur.color += cur.throughput * getEnvLight(envmap, envmapWidth, envmapHeight, cur.ray.direction, numLights); 
			}
			cur.remainingBounces = 0; // terminate path
		}
	}
}

__global__ void shadeSimpleMaterials(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		PathSegment segment = pathSegments[idx];

		if (intersection.t > 0.0f) { // if the intersection exists...
			segment.remainingBounces--;
			// Set up the RNG
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, segment.remainingBounces);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				segment.color += segment.throughput * (materialColor * material.emittance);
				segment.remainingBounces = 0;
			}
			else {
				segment.throughput *= materialColor;
				glm::vec3 intersectPos = intersection.t * segment.ray.direction + segment.ray.origin;
				glm::vec3 newDirection;
				if (material.reflectivity > 0.0f) {
					newDirection = glm::reflect(segment.ray.direction, intersection.surfaceNormal);
				}
				else {
					float pdf = 1.0f;
					newDirection = calculateRandomDirectionInHemisphere(intersection.surfaceNormal, rng, pdf);
				}

				segment.ray.direction = newDirection;
				segment.ray.origin = intersectPos + (newDirection * 0.001f);
			}

			if (segment.remainingBounces == 0) {
				segment.color += segment.throughput;
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		}
		else {
			segment.color = glm::vec3(0.0f);
			segment.remainingBounces = 0;
		}

		pathSegments[idx] = segment;
	}
}

__global__ void generateGBuffer(
	int num_paths,
	ShadeableIntersection* shadeableIntersections,
	PathSegment* pathSegments,
	GBufferPixel* gBuffer) {
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection curIsect = shadeableIntersections[idx];
		//gBuffer[idx].t = curIsect.t;
#if GBUFFER_OCT
		// encode
		glm::vec3 nor = curIsect.surfaceNormal;
		glm::vec2 p = glm::vec2(nor.x, nor.y) * (1.0f / (abs(nor.x) + abs(nor.y) + abs(nor.z)));
		gBuffer[idx].oct_normal = (nor.z <= 0.0) ? 
			((1.0f - abs(glm::vec2(p.y, p.x))) * glm::vec2(p.x >= 0 ? 1.f : -1.f, p.y >= 0 ? 1.f : -1.f)) : p;
#else
		gBuffer[idx].normal = curIsect.surfaceNormal;
#endif
#if GBUFFER_Z
		gBuffer[idx].z = curIsect.t;
#else
		gBuffer[idx].position = curIsect.t < 0.0f ? glm::vec3(0.f) : getPointOnRay(pathSegments[idx].ray, curIsect.t);
#endif
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

__global__ void aTrousFilter(const Camera cam, GBufferPixel* gbuffer, const glm::vec3* image, glm::vec3* nextImage,
	float colorWeight, float normalWeight, float positionWeight, int step) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	glm::ivec2 resolution = cam.resolution;

	if (x < resolution.x && y < resolution.y) 
	{
		// 5 * 5 kernel, B3 spline interpolation
		const float kernel[3] = {3.f / 8.f, 1.f / 4.f, 1.f / 16.f};
		glm::vec3 colorSum(0.f);
		float weightSum = 0.f;

		int index = x + y * resolution.x;
		GBufferPixel curPixel = gbuffer[index];
		glm::vec3 color = image[index];

#if GBUFFER_OCT
		glm::vec3 normal = decodeOct(curPixel.oct_normal);
#else
		glm::vec3 normal = curPixel.normal;
#endif

#if GBUFFER_Z
		const glm::vec3 position = restoreZdepth(curPixel.z, x, y, cam);
#else
		const glm::vec3 position = curPixel.position;
#endif

		for (int i = -2; i <= 2; ++i) {
			for (int j = -2; j <= 2; ++j) {
				int xIndex = glm::clamp(x + i * step, 0, resolution.x - 1);
				int yIndex = glm::clamp(y + j * step, 0, resolution.y - 1);
				int curIndex = xIndex + yIndex * resolution.x;

				// calculate weight - di
				glm::vec3 colorDiff = color - image[curIndex];
#if GBUFFER_OCT
				glm::vec3 normalDiff = normal - decodeOct(gbuffer[curIndex].oct_normal);
#else
				glm::vec3 normalDiff = normal - gbuffer[curIndex].normal;
#endif	
#if GBUFFER_Z
				glm::vec3 positionDiff = position - restoreZdepth(gbuffer[curIndex].z, xIndex, y, cam);
#else
				glm::vec3 positionDiff = position - gbuffer[curIndex].position;
#endif
				float weight = min(exp(-dot(colorDiff, colorDiff) / colorWeight), 1.0f) *
							   min(exp(-max(dot(normalDiff, normalDiff), 0.0f) / normalWeight), 1.0f) *
					           min(exp(-dot(positionDiff, positionDiff) / positionWeight), 1.0f);

				float h = kernel[abs(i)] * kernel[abs(j)];
				colorSum += h * weight * image[curIndex];
				weightSum += h * weight;
			}
		}

		nextImage[index] = colorSum / weightSum;
	}
}

__global__ void gaussianFilter(glm::ivec2 resolution, const glm::vec3* in_image, glm::vec3* out_image, const float* kernel, int radius) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;
	int index = x + y * resolution.x;

	
	if (x < resolution.x && y < resolution.y) {
		glm::vec3 color(0.0f);

		for (int i = -radius; i <= radius; ++i) {
			for (int j = -radius; j <= radius; ++j) {
				int xIndex = glm::clamp(x + i, 0, resolution.x - 1);
				int yIndex = glm::clamp(y + j, 0, resolution.y - 1);
				int curIndex = xIndex + yIndex * resolution.x;
				color += kernel[abs(i) + abs(j) * (radius + 1)] * in_image[curIndex];
			}
		}

		out_image[index] = color;
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(32, 32);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = pixelcount;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	// Empty gbuffer
	cudaMemset(dev_gBuffer, 0, pixelcount * sizeof(GBufferPixel));

	// clean shading chunks
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	bool iterationComplete = false;
	while (!iterationComplete) {
		// clean shading chunks
		//cudaMemset(dev_intersections, 0, num_paths * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;

#if FIRST_BOUNCE_CACHE
		if (iter == 1 || depth != 0) {

	#if USE_KD_TREE
				computeIntersectionsFromKDTree << <numblocksPathSegmentTracing, blockSize1d >> > (
					depth
					, num_paths
					, dev_paths
					, dev_kdNodes
					, hst_scene->kdNodes.size()
					, dev_geoms
					, dev_intersections
					);
	#else
				computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
					depth
					, num_paths
					, dev_paths
					, dev_geoms
					, hst_scene->geoms.size()
					, dev_intersections
					);
	#endif // USE_KD_TREE

			if (depth == 0) {
				// cache
				cudaMemcpy(dev_first_bounce_cache, dev_intersections, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
			}
		} else {
			cudaMemcpy(dev_intersections, dev_first_bounce_cache, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
		}
#else
	#if USE_KD_TREE
			computeIntersectionsFromKDTree << <numblocksPathSegmentTracing, blockSize1d >> > (
				  depth
				, num_paths
				, dev_paths
				, dev_kdNodes
				, hst_scene->kdNodes.size()
				, dev_geoms
				, dev_intersections
				);
	#else
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, num_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_intersections
				);
	#endif // USE_KD_TREE
#endif
		checkCUDAError("trace one bounce");
		cudaDeviceSynchronize();

		if (depth == 0) {
			generateGBuffer << <numblocksPathSegmentTracing, blockSize1d >> > (num_paths, dev_intersections, dev_paths, dev_gBuffer);
		}
		depth++;

		// sort by material?
#if SORT_MATERIALS
		thrust::sort_by_key(thrust::device, dev_intersections, dev_intersections + num_paths, dev_paths, compareByMaterialId());
#endif
		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
	  // evaluating the BSDF.
	  // Start off with just a big kernel that handles all the different
	  // materials you have in the scenefile.
	  // TODO: compare between directly shading the path segments and shading
	  // path segments that have been reshuffled to be contiguous in memory.
#if SIMPLE
	shadeSimpleMaterials << <numblocksPathSegmentTracing, blockSize1d >> > (
		iter,
		num_paths,
		dev_intersections,
		dev_paths,
		dev_materials
		);
#endif
#if NAIVE
		shadeNaive << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			num_paths,
			dev_intersections,
			dev_paths,
			dev_materials,
			dev_envmap,
			hst_scene->hdrResult.width,
			hst_scene->hdrResult.height,
			hst_scene->numLights,
			dev_textureInfos,
			dev_texturemaps
			);
#endif
#if DIRECT_MIS
		shadeDirectMIS << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			num_paths,
			dev_intersections,
			dev_paths,
			dev_materials,
			dev_geoms,
			hst_scene->geoms.size(),
			dev_kdNodes,
			hst_scene->kdNodes.size(),
			dev_lights,
			hst_scene->numLights,
			dev_envmap,
			hst_scene->hdrResult.width,
			hst_scene->hdrResult.height
			);
#endif
#if FULL
		shadeFull << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			num_paths,
			dev_intersections,
			dev_paths,
			dev_materials,
			dev_geoms,
			hst_scene->geoms.size(),
			dev_kdNodes,
			hst_scene->kdNodes.size(),
			dev_lights,
			hst_scene->numLights,
			dev_envmap,
			hst_scene->hdrResult.width,
			hst_scene->hdrResult.height,
			dev_textureInfos,
			dev_texturemaps
			);
#endif

		// remove rays with zero remaining bounces
		dev_path_end = thrust::partition(thrust::device, dev_paths, dev_path_end, isPathValid());
		num_paths = dev_path_end - dev_paths;

		iterationComplete = (depth >= traceDepth || num_paths <= 0); // TODO: should be based off stream compaction results.

		if (guiData != NULL)
		{
			guiData->TracedDepth = depth;
		}
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> > (pixelcount, dev_image, dev_paths);

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	//sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}

// CHECKITOUT: this kernel "post-processes" the gbuffer/gbuffers into something that you can visualize for debugging.
void showGBuffer(uchar4* pbo) {
	const Camera& cam = hst_scene->state.camera;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// CHECKITOUT: process the gbuffer results and send them to OpenGL buffer for visualization
	gbufferToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, hst_scene->state.camera, dev_gBuffer);
}

void showImage(uchar4* pbo, int iter) {
	const Camera& cam = hst_scene->state.camera;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);
}

void showDenoisedImage(uchar4* pbo, int iter) {
	const Camera& cam = hst_scene->state.camera;
	const glm::ivec2 resolution = cam.resolution;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, resolution, iter, dev_denoised_image);
}

void denoise(float colorWeight, float normalWeight, float positionWeight, float filterSize, int iter) {
	const glm::ivec2 resolution = hst_scene->state.camera.resolution;
	const int pixelcount = resolution.x * resolution.y;

	const dim3 blockSize2d(32, 32);
	const dim3 blocksPerGrid2d(
		(resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// divide by iteration
	//cudaMemcpy(dev_denoised_image, dev_image, pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToDevice);
#if USE_GAUSSIAN
	if (lastFilterSize != filterSize) {
		// compute kernel
		lastFilterSize = filterSize;
		if (dev_gaussian_kernel != NULL) {
			cudaFree(dev_gaussian_kernel);
		}

		int radius = filterSize / 2 + 1;
		filterSize = 2 * radius - 1; // guarantee to be odd
		cudaMalloc(&dev_gaussian_kernel, radius * radius * sizeof(float));

		float* hst_gaussian_kernel = new float[radius * radius];
		float sum = 0.0f;
		for (int i = 0; i < radius; ++i) {
			for (int j = 0; j < radius; ++j) {
				hst_gaussian_kernel[i * radius + j] =
					exp(-(i * i + j * j) / (2.0f * sigma * sigma)) / (TWO_PI * sigma * sigma);

				if (i == 0 && j == 0) {
					sum += hst_gaussian_kernel[i * radius + j];
				} else if (i == 0 || j == 0) {
					sum += 2.0f * hst_gaussian_kernel[i * radius + j];
				} else {
					sum += 4.0f * hst_gaussian_kernel[i * radius + j];
				}
			}
		}

		// normalize
		for (int i = 0; i < radius; ++i) {
			for (int j = 0; j < radius; ++j) {
				hst_gaussian_kernel[i * radius + j] /= sum;
			}
		}

		cudaMemcpy(dev_gaussian_kernel, hst_gaussian_kernel, radius * radius * sizeof(float), cudaMemcpyHostToDevice);

		/*const dim3 kernelSize2d(radius, radius);
		generateGaussianKernel << <1, kernelSize2d, radius * radius >> > (radius, dev_gaussian_kernel);*/
		delete[] hst_gaussian_kernel;
	}

	gaussianFilter << <blocksPerGrid2d, blockSize2d >> > (resolution, dev_image, dev_denoised_image, dev_gaussian_kernel, filterSize / 2);
#else
	copyImage << <blocksPerGrid2d, blockSize2d >> > (resolution, iter, dev_image, dev_denoised_image);
	// iteration determined by desired filter size
	int iterCount = (int)(glm::log2((float)filterSize / 4.0f));
	int step = 1;
	// a-trous filter
	for (int i = 0; i < iterCount; i++) {
		aTrousFilter << <blocksPerGrid2d, blockSize2d >> > (hst_scene->state.camera, dev_gBuffer, dev_denoised_image, dev_denoised_image_next,
			colorWeight, normalWeight, positionWeight, step);

		std::swap(dev_denoised_image, dev_denoised_image_next);
		step <<= 1;
	}
	restoreImage<<<blocksPerGrid2d, blockSize2d >> > (resolution, iter, dev_denoised_image);
#endif
	cudaMemcpy(hst_scene->state.image.data(), dev_denoised_image, pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
}
