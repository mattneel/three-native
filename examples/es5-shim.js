// Minimal ES5+ shims for mquickjs runtime

if (typeof Symbol === "undefined") {
  var Symbol = {
    iterator: "@@iterator",
    toStringTag: "@@toStringTag",
    toPrimitive: "@@toPrimitive",
  };
}

if (!Object.assign) {
  Object.assign = function (target) {
    if (target == null) throw new TypeError("Cannot convert undefined or null to object");
    var to = Object(target);
    for (var i = 1; i < arguments.length; i++) {
      var next = arguments[i];
      if (next == null) continue;
      for (var key in next) {
        if (Object.prototype.hasOwnProperty.call(next, key)) {
          to[key] = next[key];
        }
      }
    }
    return to;
  };
}

if (!Object.getOwnPropertySymbols) {
  Object.getOwnPropertySymbols = function () {
    return [];
  };
}

if (!Object.getOwnPropertyNames) {
  Object.getOwnPropertyNames = function (obj) {
    var out = [];
    for (var key in obj) {
      if (Object.prototype.hasOwnProperty.call(obj, key)) {
        out.push(key);
      }
    }
    return out;
  };
}

if (!Object.getOwnPropertyDescriptor) {
  Object.getOwnPropertyDescriptor = function (obj, key) {
    if (!Object.prototype.hasOwnProperty.call(obj, key)) return void 0;
    return {
      value: obj[key],
      writable: true,
      enumerable: true,
      configurable: true,
    };
  };
}

if (!Object.getOwnPropertyDescriptors) {
  Object.getOwnPropertyDescriptors = function (obj) {
    var out = {};
    for (var key in obj) {
      if (Object.prototype.hasOwnProperty.call(obj, key)) {
        out[key] = Object.getOwnPropertyDescriptor(obj, key);
      }
    }
    return out;
  };
}

if (!Object.defineProperties) {
  Object.defineProperties = function (obj, props) {
    for (var key in props) {
      if (Object.prototype.hasOwnProperty.call(props, key)) {
        Object.defineProperty(obj, key, props[key]);
      }
    }
    return obj;
  };
}

// Patch Object.create to accept property descriptors.
if (!Object.create || !Object.create.__three_native_patched__) {
  Object.create = function (proto, props) {
    function F() {}
    F.prototype = proto;
    var obj = new F();
    if (props) Object.defineProperties(obj, props);
    return obj;
  };
  Object.create.__three_native_patched__ = true;
}

if (!Object.setPrototypeOf) {
  Object.setPrototypeOf = function (obj, proto) {
    obj.__proto__ = proto;
    return obj;
  };
}

if (!Array.from) {
  Array.from = function (arr) {
    return Array.prototype.slice.call(arr);
  };
}

if (!Array.isArray) {
  Array.isArray = function (arr) {
    return Object.prototype.toString.call(arr) === "[object Array]";
  };
}

if (typeof Map === "undefined") {
  var Map = function Map(iterable) {
    this._keys = [];
    this._values = [];
    if (iterable) {
      for (var i = 0; i < iterable.length; i++) {
        this.set(iterable[i][0], iterable[i][1]);
      }
    }
  };
  Map.prototype.set = function (key, value) {
    var idx = this._keys.indexOf(key);
    if (idx === -1) {
      this._keys.push(key);
      this._values.push(value);
    } else {
      this._values[idx] = value;
    }
    return this;
  };
  Map.prototype.get = function (key) {
    var idx = this._keys.indexOf(key);
    return idx === -1 ? void 0 : this._values[idx];
  };
  Map.prototype.has = function (key) {
    return this._keys.indexOf(key) !== -1;
  };
  Map.prototype["delete"] = function (key) {
    var idx = this._keys.indexOf(key);
    if (idx === -1) return false;
    this._keys.splice(idx, 1);
    this._values.splice(idx, 1);
    return true;
  };
  Map.prototype.clear = function () {
    this._keys.length = 0;
    this._values.length = 0;
  };
  Map.prototype.forEach = function (fn, thisArg) {
    for (var i = 0; i < this._keys.length; i++) {
      fn.call(thisArg, this._values[i], this._keys[i], this);
    }
  };
  Object.defineProperty(Map.prototype, "size", {
    get: function () {
      return this._keys.length;
    },
  });
}

if (typeof Set === "undefined") {
  var Set = function Set(iterable) {
    this._values = [];
    if (iterable) {
      for (var i = 0; i < iterable.length; i++) this.add(iterable[i]);
    }
  };
  Set.prototype.add = function (value) {
    if (this._values.indexOf(value) === -1) this._values.push(value);
    return this;
  };
  Set.prototype.has = function (value) {
    return this._values.indexOf(value) !== -1;
  };
  Set.prototype["delete"] = function (value) {
    var idx = this._values.indexOf(value);
    if (idx === -1) return false;
    this._values.splice(idx, 1);
    return true;
  };
  Set.prototype.clear = function () {
    this._values.length = 0;
  };
  Set.prototype.forEach = function (fn, thisArg) {
    for (var i = 0; i < this._values.length; i++) {
      fn.call(thisArg, this._values[i], this._values[i], this);
    }
  };
  Object.defineProperty(Set.prototype, "size", {
    get: function () {
      return this._values.length;
    },
  });
}

if (typeof WeakMap === "undefined") {
  var WeakMap = function WeakMap(iterable) {
    this._map = new Map(iterable);
  };
  WeakMap.prototype.set = function (key, value) {
    this._map.set(key, value);
    return this;
  };
  WeakMap.prototype.get = function (key) {
    return this._map.get(key);
  };
  WeakMap.prototype.has = function (key) {
    return this._map.has(key);
  };
  WeakMap.prototype["delete"] = function (key) {
    return this._map["delete"](key);
  };
}

if (typeof WeakSet === "undefined") {
  var WeakSet = function WeakSet(iterable) {
    this._set = new Set(iterable);
  };
  WeakSet.prototype.add = function (value) {
    this._set.add(value);
    return this;
  };
  WeakSet.prototype.has = function (value) {
    return this._set.has(value);
  };
  WeakSet.prototype["delete"] = function (value) {
    return this._set["delete"](value);
  };
}

// Make Function.prototype.apply accept array-like objects.
if (!Function.prototype.apply.__three_native_patched__) {
  var __origApply = Function.prototype.apply;
  Function.prototype.apply = function (thisArg, args) {
    if (args == null) {
      args = [];
    } else if (!Array.isArray(args)) {
      var arr = [];
      for (var i = 0; i < args.length; i++) arr[i] = args[i];
      args = arr;
    }
    return __origApply.call(this, thisArg, args);
  };
  Function.prototype.apply.__three_native_patched__ = true;
}
