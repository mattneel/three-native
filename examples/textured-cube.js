// Textured cube example - matches Three.js webgl_geometry_cube.html
// Uses TextureLoader like real Three.js examples

load("examples/three.es5.js");

var camera, scene, renderer;
var mesh;

init();

function init() {
  camera = new THREE.PerspectiveCamera(70, 800 / 600, 0.1, 100);
  camera.position.z = 2;

  scene = new THREE.Scene();

  // Use TextureLoader like the real Three.js example
  var texture = new THREE.TextureLoader().load('deps/three/examples/textures/crate.gif');
  texture.colorSpace = THREE.SRGBColorSpace;

  var geometry = new THREE.BoxGeometry();
  var material = new THREE.MeshBasicMaterial({ map: texture });

  mesh = new THREE.Mesh(geometry, material);
  scene.add(mesh);

  renderer = new THREE.WebGLRenderer();
  renderer.setSize(800, 600);
  renderer.setAnimationLoop(animate);
  document.body.appendChild(renderer.domElement);
}

function animate() {
  mesh.rotation.x += 0.005;
  mesh.rotation.y += 0.01;

  renderer.render(scene, camera);
}
