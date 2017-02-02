jQuery(function () {
    var form = jQuery('form#rights-debugger');
    var refreshResults = function () {
        jQuery.ajax({
            url: form.attr('action'),
            data: form.serializeArray(),
            timeout: 30000, /* 30 seconds */
            success: function (response) {
            },
            error: function (xhr, reason) {
            }
        });
    };

    form.find('.search input').on('input', function () {
        refreshResults();
    });
});
