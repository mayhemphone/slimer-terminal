// Intentionally broken module: a syntax error. The converter must record it
// under `failed` and keep going.
export default {
  name: "broken",
  description: "this object literal never closes",
  options: [
    { name: "--oops" ,
