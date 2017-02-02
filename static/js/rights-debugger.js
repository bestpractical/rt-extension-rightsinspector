jQuery(function () {
    var template = jQuery('script#debugger-result').html();
    if (!template) {
        return;
    }

    var renderItem = Handlebars.compile(template);
    var form = jQuery('form#rights-debugger');
    var display = form.find('.results');

    var refreshResults = function () {
        display.empty();

        jQuery.ajax({
            url: form.attr('action'),
            data: form.serializeArray(),
            timeout: 30000, /* 30 seconds */
            success: function (response) {
                display.empty(); // just in case of race condition
                var items = response.results;
                jQuery.each(items, function (i, item) {
                    display.append(renderItem(item));
                });
            },
            error: function (xhr, reason) {
            }
        });
    };

    form.find('.search input').on('input', function () {
        refreshResults();
    });

    refreshResults();
});
