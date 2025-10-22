# CodeApp Node.js Utilities

A collection of common utility functions for use in CodeApp.

## Installation

### Via VISX Package

1. Create the VISX package:
   ```bash
   python create_visx.py examples/node-utils node-utils.visx --type node
   ```

2. Install in CodeApp:
   - Open VISX Packages panel
   - Download from URL or select local file
   - Package will be installed automatically

### Manual Installation

Copy the files to your CodeApp workspace and require as needed.

## Available Functions

### `formatDate(date)`
Format a date object to ISO date string (YYYY-MM-DD).

```javascript
const utils = require('codeapp-node-utils');
console.log(utils.formatDate()); // "2025-10-21"
```

### `randomString(length)`
Generate a random alphanumeric string.

```javascript
const id = utils.randomString(16); // "a3B9xK2mP1qR7sT4"
```

### `deepClone(obj)`
Create a deep copy of an object.

```javascript
const original = { a: 1, b: { c: 2 } };
const copy = utils.deepClone(original);
```

### `sleep(ms)`
Async sleep for specified milliseconds.

```javascript
await utils.sleep(1000); // Wait 1 second
```

### `retry(fn, maxRetries, delay)`
Retry a function with exponential backoff.

```javascript
const result = await utils.retry(
    async () => fetchData(),
    maxRetries: 3,
    delay: 1000
);
```

### `debounce(fn, delay)`
Debounce a function to limit execution rate.

```javascript
const debouncedSearch = utils.debounce((query) => {
    performSearch(query);
}, 300);
```

### `throttle(fn, limit)`
Throttle a function to execute at most once per time period.

```javascript
const throttledScroll = utils.throttle((event) => {
    handleScroll(event);
}, 100);
```

## Testing

Run the test suite:

```bash
npm test
# or
node test.js
```

## License

MIT
