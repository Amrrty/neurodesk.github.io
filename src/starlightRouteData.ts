import { defineRouteMiddleware } from '@astrojs/starlight/route-data';

const DEVELOPER_GROUP = 'For developers';

export const onRequest = defineRouteMiddleware((context) => {
	const route = context.locals.starlightRoute;
	const path = context.url.pathname;

	// Developer docs get their own sidebar; the header links cross between them.
	const inDevelopers = path.startsWith('/developers');
	route.sidebar = route.sidebar
		.filter((entry) =>
			inDevelopers ? entry.label === DEVELOPER_GROUP : entry.label !== DEVELOPER_GROUP
		)
		.map((entry) =>
			inDevelopers && entry.type === 'group' ? { ...entry, collapsed: false } : entry
		);
});
