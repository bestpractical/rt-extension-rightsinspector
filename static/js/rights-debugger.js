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
    var loading = form.find('.search .loading');

    var revoking = {};
    var existingRequest;

    var buttonForAction = function (action) {
        return display.find('.revoke button[data-action="' + action + '"]');
    };

    var displayRevoking = function (button) {
        button.addClass('ui-state-disabled').prop('disabled', true);
        button.after(loading.clone());
    };

    var refreshResults = function () {
        form.addClass('refreshing');
        form.find('button').addClass('ui-state-disabled').prop('disabled', true);

        var serialized = form.serializeArray();
        var search = {};
        jQuery.each(serialized, function(i, field){
            search[field.name] = field.value;
        });

        if (existingRequest) {
            existingRequest.abort();
        }

        existingRequest = jQuery.ajax({
            url: form.attr('action'),
            data: search,
            timeout: 30000, /* 30 seconds */
            success: function (response) {
                form.removeClass('refreshing').removeClass('error');
                display.empty();

                var items = response.results;
                jQuery.each(items, function (i, item) {
                    display.append(renderItem({ search: search, item: item }));
                });

                jQuery.each(revoking, function (key, value) {
                    var revokeButton = buttonForAction(key);
                    displayRevoking(revokeButton);
                });
            },
            error: function (xhr, reason) {
                if (reason == 'abort') {
                    return;
                }

                form.removeClass('refreshing').addClass('error');
                display.empty();
                display.text('Error: ' + xhr.statusText);
            }
        });
    };

    display.on('click', '.revoke button', function (e) {
        e.preventDefault();
        var button = jQuery(e.target);
        var action = button.data('action');

        displayRevoking(button);

        revoking[action] = 1;

        jQuery.ajax({
            url: action,
            timeout: 30000, /* 30 seconds */
            success: function (response) {
                button = buttonForAction(action);
                if (!button.length) {
                    alert(response.msg);
                }
                else {
                    button.closest('.revoke').text(response.msg);
                }
                delete revoking[action];
            },
            error: function (xhr, reason) {
                button = buttonForAction(action);
                button.closest('.revoke').text(reason);
                delete revoking[action];
                alert(reason);
            }
        });
    });

    form.find('.search input').on('input', function () {
        refreshResults();
    });

    refreshResults();
});
