-- busted helper: make the repo root and tests/helpers importable.
package.path = "./?.lua;./tests/?.lua;./tests/helpers/?.lua;" .. package.path
