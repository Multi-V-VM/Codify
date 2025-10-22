const utils = require('./index');

console.log('Testing CodeApp Node.js Utilities...\n');

// Test formatDate
console.log('formatDate():', utils.formatDate());

// Test randomString
console.log('randomString(16):', utils.randomString(16));

// Test deepClone
const obj = { a: 1, b: { c: 2 } };
const cloned = utils.deepClone(obj);
cloned.b.c = 3;
console.log('Original object:', obj);
console.log('Cloned object:', cloned);

// Test sleep
(async () => {
    console.log('\nTesting sleep(1000)...');
    await utils.sleep(1000);
    console.log('Sleep completed!');

    // Test retry
    let attemptCount = 0;
    const unreliableFunction = async () => {
        attemptCount++;
        if (attemptCount < 3) {
            throw new Error('Not yet!');
        }
        return 'Success!';
    };

    console.log('\nTesting retry()...');
    const result = await utils.retry(unreliableFunction, 5, 100);
    console.log('Retry result:', result, '(took', attemptCount, 'attempts)');

    console.log('\nAll tests passed! ✅');
})();
