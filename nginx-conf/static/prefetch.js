// prefetch.js
(function() {
    var prefetchLinks = document.querySelectorAll('link[rel=prefetch]');
    for (var i = 0; i < prefetchLinks.length; i++) {
        var link = prefetchLinks[i];
        var url = link.href;
        fetch(url, { method: 'HEAD' });
    }
})();
