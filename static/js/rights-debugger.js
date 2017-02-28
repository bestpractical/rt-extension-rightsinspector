jQuery(function () {
    var recordTemplate = jQuery('script#debugger-record-template').html();
    var resultTemplate = jQuery('script#debugger-result-template').html();
    if (!recordTemplate || !resultTemplate) {
        return;
    }

    Handlebars.registerPartial('render_record', recordTemplate);

    Handlebars.registerHelper('search_highlight', function (text, term) {
        // this is simplistic; better would be to highlight on the
        // unescaped text, and case insensitively
        text = Handlebars.Utils.escapeExpression(text);
        text = text.replace(term, '<span class="match">' + term + '</span>');
        return new Handlebars.SafeString(text);
    });

    var renderItem = Handlebars.compile(resultTemplate);
    var form = jQuery('form#rights-debugger');
    var display = form.find('.results');

    var refreshResults = function () {
        form.addClass('refreshing');

        var serialized = form.serializeArray();
        var search = {};
        jQuery.each(serialized, function(i, field){
            search[field.name] = field.value;
        });

        jQuery.ajax({
            url: form.attr('action'),
            data: search,
            timeout: 30000, /* 30 seconds */
            success: function (response) {
                form.removeClass('refreshing');
                display.empty(); // just in case of race condition
                var items = response.results;
                jQuery.each(items, function (i, item) {
                    display.append(renderItem({ search: search, item: item }));
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
