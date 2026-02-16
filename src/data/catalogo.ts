export type CatalogoProduct = {
	id: string;
	category: string;
	brand: string;
	name: string;
	description: string;
	productImage: string;
	brandImage?: string;
};

export const catalogoProducts: CatalogoProduct[] = [
	{
		id: 'p-001',
		category: 'Protección Ocular',
		brand: 'LIBUS',
		name: 'Protector ocular Argon tono gris antirraye',
		description:
			'El Libus Argon tono gris es un anteojo de seguridad diseñado para ofrecer una visión cómoda y protegida en entornos con alta luminosidad o exposición solar. Su lente con tratamiento antirrayas garantiza mayor durabilidad y mantiene una visión clara incluso tras un uso continuo.',
		productImage: '/catalogo/productos/argón-gris.png',
		brandImage: '/catalogo/marcas/libus.png',
	},
];
