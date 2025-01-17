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

#define SORT_MATERIALS 0
#define FIRST_BOUNCE_CACHE 1
#define ANTI_ALIASING 1

#define NAIVE 0
#define DIRECT_MIS 0
#define FULL 1
#define RUSSIAN_ROULETTE 1

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

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3* dev_image = NULL;
static Geom* dev_geoms = NULL;
static Light* dev_lights = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static ShadeableIntersection* dev_intersections = NULL;

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
					intersection.surfaceNormal, intersection.surfaceTangent, material, rng);
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
			scatterRay(cur, point, intersection.surfaceNormal, intersection.surfaceTangent, material, rng);
				
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

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4* pbo, int frame, int iter) {
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

	bool iterationComplete = false;
	while (!iterationComplete) {
		// clean shading chunks
		cudaMemset(dev_intersections, 0, num_paths * sizeof(ShadeableIntersection));

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
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}
