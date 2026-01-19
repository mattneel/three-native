// three.js minimal scene example (from manual "Creating a scene")
// Runs in three-native by loading the ES5 bundle.

load("examples/three.es5.js");

var scene = new THREE.Scene();
var camera = new THREE.PerspectiveCamera(75, 800 / 600, 0.1, 1000);

var renderer = new THREE.WebGLRenderer();
renderer.setSize(800, 600);
renderer.setAnimationLoop(animate);
document.body.appendChild(renderer.domElement);

var geometry = new THREE.BoxGeometry(1, 1, 1);
var material = new THREE.MeshBasicMaterial({ color: 0x00ff00 });
var cube = new THREE.Mesh(geometry, material);
scene.add(cube);

camera.position.z = 5;

function animate(time) {
  cube.rotation.x = time / 2000;
  cube.rotation.y = time / 1000;
  renderer.render(scene, camera);
}
