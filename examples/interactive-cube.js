// Interactive cube example - tests event handling
// Demonstrates mouse and keyboard events

load("examples/three.es5.js");

var camera, scene, renderer;
var mesh;
var targetRotationX = 0;
var targetRotationY = 0;
var mouseDown = false;
var mouseX = 0, mouseY = 0;

init();

function init() {
  camera = new THREE.PerspectiveCamera(70, 800 / 600, 0.1, 100);
  camera.position.z = 2;

  scene = new THREE.Scene();

  // Use TextureLoader for the crate texture
  var texture = new THREE.TextureLoader().load('examples/crate.png');
  texture.colorSpace = THREE.SRGBColorSpace;

  var geometry = new THREE.BoxGeometry();
  var material = new THREE.MeshBasicMaterial({ map: texture });

  mesh = new THREE.Mesh(geometry, material);
  scene.add(mesh);

  renderer = new THREE.WebGLRenderer();
  renderer.setSize(800, 600);
  renderer.setAnimationLoop(animate);
  document.body.appendChild(renderer.domElement);

  // Event listeners for interaction
  window.addEventListener('mousedown', onMouseDown);
  window.addEventListener('mouseup', onMouseUp);
  window.addEventListener('mousemove', onMouseMove);
  window.addEventListener('wheel', onWheel);
  window.addEventListener('keydown', onKeyDown);

  print("[interactive-cube] Initialized - drag to rotate, scroll to zoom, arrow keys to move");
}

function onMouseDown(event) {
  mouseDown = true;
  mouseX = event.clientX;
  mouseY = event.clientY;
  print("[interactive-cube] mousedown at " + mouseX + ", " + mouseY + " button=" + event.button);
}

function onMouseUp(event) {
  mouseDown = false;
  print("[interactive-cube] mouseup");
}

function onMouseMove(event) {
  if (mouseDown) {
    var deltaX = event.clientX - mouseX;
    var deltaY = event.clientY - mouseY;

    targetRotationY += deltaX * 0.01;
    targetRotationX += deltaY * 0.01;

    mouseX = event.clientX;
    mouseY = event.clientY;
  }
}

function onWheel(event) {
  camera.position.z += event.deltaY * 0.001;
  if (camera.position.z < 0.5) camera.position.z = 0.5;
  if (camera.position.z > 10) camera.position.z = 10;
  print("[interactive-cube] wheel deltaY=" + event.deltaY + " zoom=" + camera.position.z.toFixed(2));
}

function onKeyDown(event) {
  print("[interactive-cube] keydown key='" + event.key + "' code=" + event.code + " keyCode=" + event.keyCode);

  var moveSpeed = 0.1;

  if (event.code === 'ArrowUp' || event.key === 'w') {
    mesh.position.y += moveSpeed;
  } else if (event.code === 'ArrowDown' || event.key === 's') {
    mesh.position.y -= moveSpeed;
  } else if (event.code === 'ArrowLeft' || event.key === 'a') {
    mesh.position.x -= moveSpeed;
  } else if (event.code === 'ArrowRight' || event.key === 'd') {
    mesh.position.x += moveSpeed;
  } else if (event.key === 'r') {
    // Reset position and rotation
    mesh.position.set(0, 0, 0);
    mesh.rotation.set(0, 0, 0);
    targetRotationX = 0;
    targetRotationY = 0;
    camera.position.z = 2;
    print("[interactive-cube] reset");
  }
}

function animate() {
  // Smooth rotation towards target
  mesh.rotation.x += (targetRotationX - mesh.rotation.x) * 0.1;
  mesh.rotation.y += (targetRotationY - mesh.rotation.y) * 0.1;

  renderer.render(scene, camera);
}
